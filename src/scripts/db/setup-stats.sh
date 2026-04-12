#!/usr/bin/env bash
# =============================================================================
# setup-stats.sh — STATS-CEB database setup
#
# Usage:
#   bash scripts/db/setup-stats.sh [--with-queries]
#
# Default:  Create DB, load data, install AQO, load token_embeddings.
#           Query extraction is SKIPPED (uses pre-existing queries).
# --with-queries:
#           Extract queries from the workload file and validate each one
#           against the live database.
#
# NOTE: STATS-CEB queries are extracted from a workload file (not generated
#       from templates). The workload is part of the benchmark repo clone.
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
            echo "--with-queries: extract + validate STATS-CEB queries from workload file."
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

DB="${STATS_DB}"
WORK_DIR="/tmp/stats-build"

echo "=================================="
echo "STATS-CEB Setup"
echo "DB: ${DB}"
echo "With queries: ${WITH_QUERIES}"
echo "=================================="

# ── Step 1: Install build dependencies ───────────────────────────────────────
echo ""
echo "-- Step 1: Install dependencies"
sudo apt-get update -qq
sudo apt-get install -y build-essential git

# ── Step 2: Prepare working directories ──────────────────────────────────────
echo ""
echo "-- Step 2: Prepare directories"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# ── Step 3: Clone End-to-End-CardEst-Benchmark ───────────────────────────────
echo ""
echo "-- Step 3: Clone End-to-End-CardEst-Benchmark repo"
git clone https://github.com/Nathaniel-Han/End-to-End-CardEst-Benchmark.git "${WORK_DIR}"

# ── Step 4: (Re)create database ───────────────────────────────────────────────
echo ""
echo "-- Step 4: Create database '${DB}'"
pg_ensure_running

$PSQL -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '${DB}' AND pid <> pg_backend_pid();
" || true
$PSQL -c "DROP DATABASE IF EXISTS ${DB};"
$PG_BIN/createdb "${DB}"
echo "  [OK] Database '${DB}' created"

# ── Step 5: Create schema ─────────────────────────────────────────────────────
echo ""
echo "-- Step 5: Create schema"
$PSQL "${DB}" -f "${WORK_DIR}/datasets/stats_simplified/stats.sql"
echo "  [OK] Schema created"

# ── Step 6: Load data ─────────────────────────────────────────────────────────
echo ""
echo "-- Step 6: Load data"
$PSQL "${DB}" -f "${WORK_DIR}/scripts/sql/stats_load.sql"
echo "  [OK] Data loaded"

# ── Step 7: Create indexes ────────────────────────────────────────────────────
echo ""
echo "-- Step 7: Create indexes"
$PSQL "${DB}" -f "${WORK_DIR}/scripts/sql/stats_index.sql"
echo "  [OK] Indexes created"

# ── Step 8: Analyze ───────────────────────────────────────────────────────────
echo ""
echo "-- Step 8: Analyze tables"
$PSQL "${DB}" -c "ANALYZE;"
echo "  [OK] ANALYZE complete"

# ── Step 9: Install AQO + load token_embeddings ──────────────────────────────
echo ""
echo "-- Step 9: Install AQO extension"
ensure_aqo_in_db "${DB}"

echo ""
echo "-- Step 10: Load token_embeddings"
load_token_embeddings "${DB}"

# ── Step 11 (optional): Extract and validate queries ─────────────────────────
if [ "${WITH_QUERIES}" = "true" ]; then
    echo ""
    echo "-- Step 11: Extract STATS-CEB queries from workload file"

    QUERY_DIR="${EXPERIMENT_DIR}/stats/queries"
    mkdir -p "${QUERY_DIR}"

    WORKLOAD_FILE="${WORK_DIR}/workloads/stats_CEB/stats_CEB.sql"
    if [ ! -f "${WORKLOAD_FILE}" ]; then
        echo "  [ERROR] Workload file not found: ${WORKLOAD_FILE}" >&2
        exit 1
    fi

    # STATS-CEB format: each line is "true_card||SELECT ...;"
    # Strip the true cardinality prefix and write numbered SQL files.
    _idx=0
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        _idx=$((_idx+1))
        _fname="q$(printf '%03d' "${_idx}").sql"
        echo "${line#*||}" > "${QUERY_DIR}/${_fname}"
    done < "${WORKLOAD_FILE}"
    echo "  Extracted ${_idx} queries"

    echo ""
    echo "-- Step 12: Validate queries (skip errors and queries > 55s)"
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
    echo "-- Step 11: [SKIP] Query extraction skipped (use --with-queries to enable)"
    echo "  Note: pre-existing files in ${EXPERIMENT_DIR}/stats/queries/ are used as-is."
fi

echo ""
echo "=================================="
echo "STATS-CEB Setup Completed"
echo "Database : ${DB}"
echo "Queries  : ${EXPERIMENT_DIR}/stats/queries"
echo "=================================="
