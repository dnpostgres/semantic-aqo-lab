#!/usr/bin/env bash
# =============================================================================
# setup-tpcds.sh — TPC-DS 1GB database setup
#
# Usage:
#   bash scripts/db/setup-tpcds.sh [--with-queries]
#
# Default:  Create DB, load data, install AQO, load token_embeddings.
#           Query generation is SKIPPED (uses pre-existing queries).
# --with-queries:
#           Also generate all 99 templates x 20 seeds and validate each
#           query (expensive: can take many hours).
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
            echo "--with-queries: also generate and validate TPC-DS queries (expensive)."
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

DB="${TPCDS_DB}"
WORK_DIR="/tmp/tpcds-build"
DATA_DIR="/tmp/tpcds-data"
SCALE=1

echo "=================================="
echo "TPC-DS Setup (SF=${SCALE})"
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
rm -rf "${WORK_DIR}" "${DATA_DIR}"
mkdir -p "${WORK_DIR}"
mkdir -p "${DATA_DIR}"

# ── Step 3: Clone tpcds-kit ───────────────────────────────────────────────────
echo ""
echo "-- Step 3: Download tpcds-kit"
git clone https://github.com/gregrahn/tpcds-kit.git "${WORK_DIR}"

# ── Step 4: Fix GCC >= 10 build issue ────────────────────────────────────────
echo ""
echo "-- Step 4: Fix GCC >= 10 build issue"
sed -i 's/-g -Wall/-g -Wall -fcommon/' "${WORK_DIR}/tools/makefile"

# ── Step 5: Build dsdgen ──────────────────────────────────────────────────────
echo ""
echo "-- Step 5: Build dsdgen"
cd "${WORK_DIR}/tools"
make

# ── Step 6: Generate TPC-DS data ─────────────────────────────────────────────
echo ""
echo "-- Step 6: Generate TPC-DS data"
./dsdgen -scale "${SCALE}" -force -dir "${DATA_DIR}"

# ── Step 7: Fix trailing pipe delimiter ───────────────────────────────────────
echo ""
echo "-- Step 7: Fix trailing delimiter"
for f in "${DATA_DIR}"/*.dat; do
    sed -i 's/|$//' "$f"
done

# ── Step 8: (Re)create database ───────────────────────────────────────────────
echo ""
echo "-- Step 8: Create database '${DB}'"
pg_ensure_running

$PSQL -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '${DB}' AND pid <> pg_backend_pid();
" || true
$PSQL -c "DROP DATABASE IF EXISTS ${DB};"
$PG_BIN/createdb "${DB}"
echo "  [OK] Database '${DB}' created"

# ── Step 9: Create schema ─────────────────────────────────────────────────────
echo ""
echo "-- Step 9: Create schema"
$PSQL "${DB}" -f "${WORK_DIR}/tools/tpcds.sql"
echo "  [OK] Schema created"

# ── Step 10: Bulk-load data ───────────────────────────────────────────────────
echo ""
echo "-- Step 10: Load data"
for f in "${DATA_DIR}"/*.dat; do
    table=$(basename "$f" .dat)
    echo "  Loading ${table}..."
    $PSQL "${DB}" -c "\copy ${table} FROM '${f}' DELIMITER '|' NULL ''"
done
echo "  [OK] All tables loaded"

# ── Step 11: Analyze ──────────────────────────────────────────────────────────
echo ""
echo "-- Step 11: Analyze tables"
$PSQL "${DB}" -c "ANALYZE;"
echo "  [OK] ANALYZE complete"

# ── Step 12: Install AQO + load token_embeddings ─────────────────────────────
echo ""
echo "-- Step 12: Install AQO extension"
ensure_aqo_in_db "${DB}"

echo ""
echo "-- Step 13: Load token_embeddings"
load_token_embeddings "${DB}"

# ── Step 14 (optional): Generate and validate queries ────────────────────────
if [ "${WITH_QUERIES}" = "true" ]; then
    echo ""
    echo "-- Step 14: Generate query seeds (99 templates x 20 seeds)"

    QUERY_DIR="${EXPERIMENT_DIR}/tpcds/queries"
    TMPQUERY_DIR=$(mktemp -d /tmp/tpcds-queries-XXXXXX)
    chmod 755 "${TMPQUERY_DIR}"
    mkdir -p "${QUERY_DIR}"

    # 20 diverse random seeds
    SEEDS=(42 17 99 7 1337 2024 55 123 456 789 321 654 987 111 222 333 444 555 666 777)

    # dsqgen is in $WORK_DIR/tools/
    for tpl in "${WORK_DIR}"/query_templates/query[0-9]*.tpl; do
        [ -f "${tpl}" ] || continue
        qbase=$(basename "${tpl}" .tpl)
        qnum="${qbase#query}"
        # Skip non-numeric variants (14a, 23a, 39a — included via their main template)
        [[ "${qnum}" =~ ^[0-9]+$ ]] || continue
        for seed in "${SEEDS[@]}"; do
            fname="q$(printf '%02d' "${qnum}")_s${seed}.sql"
            (
                cd "${WORK_DIR}/tools"
                ./dsqgen \
                    -template "../query_templates/${qbase}.tpl" \
                    -directory ../query_templates \
                    -rngseed "${seed}" \
                    -scale "${SCALE}" \
                    -dialect netezza \
                    -filter Y \
                    2>/dev/null
            ) | grep -v "^-- " > "${TMPQUERY_DIR}/${fname}" || true
            # Remove empty files (template failed to generate)
            [ -s "${TMPQUERY_DIR}/${fname}" ] || rm -f "${TMPQUERY_DIR}/${fname}"
        done
        echo "  Q${qnum} done (${#SEEDS[@]} variants)"
    done

    _generated=$(ls "${TMPQUERY_DIR}"/*.sql 2>/dev/null | wc -l)
    chmod 644 "${TMPQUERY_DIR}"/*.sql 2>/dev/null || true
    echo "  Generated ${_generated} query files -> validating in temp dir"

    echo ""
    echo "-- Step 15: Validate queries (skip errors and queries > 55s)"
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
    _total=$(ls "${TMPQUERY_DIR}"/*.sql 2>/dev/null | wc -l)
    _i=0
    for _qfile in "${TMPQUERY_DIR}"/*.sql; do
        [ -f "${_qfile}" ] || continue
        _i=$((_i+1))
        _qname=$(basename "${_qfile}")

        if [[ -v "_done[${_qname}]" ]]; then
            _skip=$((_skip+1))
            [ -f "${QUERY_DIR}/${_qname}" ] && _valid=$((_valid+1))
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
            cp "${_qfile}" "${QUERY_DIR}/${_qname}"
            _valid=$((_valid+1))
        elif [ ${_rc} -eq 124 ] || [ ${_rc} -eq 137 ] || \
             grep -q "canceling statement due to statement timeout" "${_stderr_file}" 2>/dev/null; then
            printf "SKIP (>55s) %3ds\n" "${_elapsed}"
            _slow=$((_slow+1))
        else
            _reason=$(grep -i 'error' "${_stderr_file}" | head -1 | cut -c1-60)
            printf "SKIP %-20s %3ds\n" "(${_reason})" "${_elapsed}"
            _err=$((_err+1))
        fi
        rm -f "${_stderr_file}"

        echo "${_qname}" >> "${CHECKPOINT_FILE}"
    done

    rm -rf "${TMPQUERY_DIR}"
    rm -f "${CHECKPOINT_FILE}"

    [ "${_skip}" -gt 0 ] && echo "  (skipped ${_skip} previously validated queries)"
    echo ""
    echo "  Kept: ${_valid} | Skipped (error): ${_err} | Skipped (timeout): ${_slow}"
    echo "  Final query count: $(ls "${QUERY_DIR}"/*.sql 2>/dev/null | wc -l)"
else
    echo ""
    echo "-- Step 14: [SKIP] Query generation skipped (use --with-queries to enable)"
fi

echo ""
echo "=================================="
echo "TPC-DS Setup Completed"
echo "Database : ${DB}"
echo "Queries  : ${EXPERIMENT_DIR}/tpcds/queries"
echo "=================================="
