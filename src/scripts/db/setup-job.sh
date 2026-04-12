#!/usr/bin/env bash
# =============================================================================
# setup-job.sh — JOB / IMDB database setup
#
# Usage:
#   bash scripts/db/setup-job.sh [--with-queries]
#
# Default:  Create DB, load data, install AQO, load token_embeddings.
#           The 113 JOB queries are hand-written and live in the repo at
#           experiment/job/queries/ — no generation step is needed.
# --with-queries:
#           Copy and validate the 113 hand-written queries from the
#           join-order-benchmark clone (removes queries that error or
#           time out against the live database).
#
# NOTE: JOB queries are not generated (unlike TPC-H/TPC-DS). --with-queries
#       only copies + validates the existing hand-written .sql files.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPTS_DIR}/lib/common.sh"

# ── Parse args ────────────────────────────────────────────────────────────────
WITH_QUERIES=false
for arg in "$@"; do
    case "$arg" in
        --with-queries) WITH_QUERIES=true ;;
        --help|-h)
            echo "Usage: bash $(basename "$0") [--with-queries]"
            echo ""
            echo "Default: create DB, load data, install AQO, load token_embeddings."
            echo "--with-queries: copy + validate the 113 JOB queries (no generation)."
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

DB="${JOB_DB}"
WORK_DIR="/tmp/job-build"
DATA_DIR="/tmp/job-data"
ARCHIVE_NAME="imdb.tgz"
ARCHIVE_URL="http://event.cwi.nl/da/job/imdb.tgz"

echo "=================================="
echo "JOB / IMDB Setup"
echo "DB: ${DB}"
echo "With queries: ${WITH_QUERIES}"
echo "=================================="

# ── Step 1: Install build dependencies ───────────────────────────────────────
echo ""
echo "-- Step 1: Install dependencies"
sudo apt-get update -qq
sudo apt-get install -y build-essential git wget tar

# ── Step 2: Prepare working directories ──────────────────────────────────────
echo ""
echo "-- Step 2: Prepare directories"
rm -rf "${WORK_DIR}" "${DATA_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${DATA_DIR}"

# ── Step 3: Clone join-order-benchmark repo ───────────────────────────────────
echo ""
echo "-- Step 3: Clone join-order-benchmark repo"
git clone https://github.com/gregrahn/join-order-benchmark.git "${WORK_DIR}"

# ── Step 4: Download IMDB dataset archive ────────────────────────────────────
echo ""
echo "-- Step 4: Download IMDB dataset archive"
wget -c -O "${WORK_DIR}/${ARCHIVE_NAME}" "${ARCHIVE_URL}"

# ── Step 5: Extract dataset ───────────────────────────────────────────────────
echo ""
echo "-- Step 5: Extract dataset"
tar -xzf "${WORK_DIR}/${ARCHIVE_NAME}" -C "${DATA_DIR}"

# ── Step 6: (Re)create database ───────────────────────────────────────────────
echo ""
echo "-- Step 6: Create database '${DB}'"
pg_ensure_running

$PSQL -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '${DB}' AND pid <> pg_backend_pid();
" || true
$PSQL -c "DROP DATABASE IF EXISTS ${DB};"
$PG_BIN/createdb "${DB}"
echo "  [OK] Database '${DB}' created"

# ── Step 7: PostgreSQL bulk-load optimizations ────────────────────────────────
echo ""
echo "-- Step 7: Bulk-load optimizations"
$PSQL "${DB}" <<SQL
SET synchronous_commit = OFF;
SET maintenance_work_mem = '2GB';
SET work_mem = '256MB';
SQL

# ── Step 8: Create schema ─────────────────────────────────────────────────────
echo ""
echo "-- Step 8: Create schema"
$PSQL "${DB}" -f "${WORK_DIR}/schema.sql"
echo "  [OK] Schema created"

# ── Step 9: Fix trailing delimiter in CSV files ───────────────────────────────
echo ""
echo "-- Step 9: Fix trailing delimiter"
for f in "${DATA_DIR}"/*.csv; do
    sed -i 's/|$//' "$f"
done

# ── Step 10: Bulk-load data ───────────────────────────────────────────────────
echo ""
echo "-- Step 10: Load data"
# IMDB CSV files use backslash-escaped quotes (\") instead of standard ("").
# Must specify ESCAPE '\' to parse correctly.
for f in "${DATA_DIR}"/*.csv; do
    table=$(basename "$f" .csv)
    echo "  Loading ${table}..."
    $PSQL "${DB}" -c "\copy ${table} FROM '${f}' CSV ESCAPE '\\'"
done
echo "  [OK] All tables loaded"

# ── Step 11: Create foreign-key indexes ──────────────────────────────────────
echo ""
echo "-- Step 11: Create foreign-key indexes (after load for speed)"
if [ -f "${WORK_DIR}/fkindexes.sql" ]; then
    $PSQL "${DB}" -f "${WORK_DIR}/fkindexes.sql"
    echo "  [OK] FK indexes created"
else
    echo "  [SKIP] fkindexes.sql not found in repo clone"
fi

# ── Step 12: Analyze ──────────────────────────────────────────────────────────
echo ""
echo "-- Step 12: Analyze tables"
$PSQL "${DB}" -c "ANALYZE;"
echo "  [OK] ANALYZE complete"

# ── Step 13: Install AQO + load token_embeddings ─────────────────────────────
echo ""
echo "-- Step 13: Install AQO extension"
ensure_aqo_in_db "${DB}"

echo ""
echo "-- Step 14: Load token_embeddings"
load_token_embeddings "${DB}"

# ── Step 15 (optional): Copy and validate queries ─────────────────────────────
if [ "${WITH_QUERIES}" = "true" ]; then
    echo ""
    echo "-- Step 15: Copy JOB queries from repo clone"

    QUERY_DIR="${EXPERIMENT_DIR}/job/queries"
    mkdir -p "${QUERY_DIR}"

    # JOB has 113 hand-written queries (1a.sql – 33c.sql)
    _copied=0
    for _qfile in "${WORK_DIR}"/[0-9]*.sql; do
        [ -f "${_qfile}" ] || continue
        cp "${_qfile}" "${QUERY_DIR}/$(basename "${_qfile}")"
        _copied=$((_copied+1))
    done
    echo "  Copied ${_copied} query files"

    echo ""
    echo "-- Step 16: Validate queries (skip errors and queries > 55s)"
    echo "   (55s statement_timeout + 60s hard kill)"

    CHECKPOINT_FILE="${QUERY_DIR}/.checkpoint"

    declare -A _done
    if [ -f "${CHECKPOINT_FILE}" ]; then
        while IFS= read -r line; do
            _done["${line}"]=1
        done < "${CHECKPOINT_FILE}"
        echo "  Resuming from checkpoint (${#_done[@]} queries already processed)"
    fi

    _valid=0; _err=0; _slow=0; _skip=0
    _total=$(ls "${QUERY_DIR}"/*.sql 2>/dev/null | wc -l)
    _i=0
    for _qfile in "${QUERY_DIR}"/*.sql; do
        [ -f "${_qfile}" ] || continue
        _i=$((_i+1))
        _qname=$(basename "${_qfile}")

        if [[ -v "_done[${_qname}]" ]]; then
            _skip=$((_skip+1))
            _valid=$((_valid+1))
            continue
        fi

        printf "  [%d/%d] %-36s" "${_i}" "${_total}" "${_qname}"

        _stderr_file=$(mktemp)
        _t0=$SECONDS
        _rc=0
        sudo -u postgres timeout --kill-after=5 60 \
            "${PG_BIN}/psql" -d "${DB}" -v ON_ERROR_STOP=1 -X -q \
            -c "SET statement_timeout = '55s';" \
            -f "${_qfile}" \
            > /dev/null 2>"${_stderr_file}" || _rc=$?
        _elapsed=$(( SECONDS - _t0 ))

        if [ ${_rc} -eq 0 ]; then
            printf "OK          %3ds\n" "${_elapsed}"
            _valid=$((_valid+1))
        elif [ ${_rc} -eq 124 ] || [ ${_rc} -eq 137 ] || \
             grep -q "canceling statement due to statement timeout" "${_stderr_file}" 2>/dev/null; then
            printf "SKIP (>55s) %3ds\n" "${_elapsed}"
            rm -f "${_qfile}"
            _slow=$((_slow+1))
        else
            _reason=$(grep -i 'error' "${_stderr_file}" | head -1 | cut -c1-60)
            printf "SKIP %-20s %3ds\n" "(${_reason})" "${_elapsed}"
            rm -f "${_qfile}"
            _err=$((_err+1))
        fi
        rm -f "${_stderr_file}"

        echo "${_qname}" >> "${CHECKPOINT_FILE}"
    done

    rm -f "${CHECKPOINT_FILE}"

    [ "${_skip}" -gt 0 ] && echo "  (skipped ${_skip} previously validated queries)"
    echo ""
    echo "  Kept: ${_valid} | Skipped (error): ${_err} | Skipped (timeout): ${_slow}"
    echo "  Final query count: $(ls "${QUERY_DIR}"/*.sql 2>/dev/null | wc -l)"
else
    echo ""
    echo "-- Step 15: [SKIP] Query validation skipped (use --with-queries to enable)"
    echo "  Note: JOB queries are hand-written; pre-existing files in"
    echo "  ${EXPERIMENT_DIR}/job/queries/ are used as-is."
fi

echo ""
echo "=================================="
echo "JOB / IMDB Setup Completed"
echo "Database : ${DB}"
echo "Queries  : ${EXPERIMENT_DIR}/job/queries"
echo "=================================="
