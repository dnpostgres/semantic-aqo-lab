#!/usr/bin/env bash
# =============================================================================
# setup-tpch.sh — TPC-H 1GB database setup
#
# Usage:
#   bash scripts/db/setup-tpch.sh [--with-queries]
#
# Default:  Create DB, load data, install AQO, load token_embeddings.
#           Query generation is SKIPPED (uses pre-existing queries).
# --with-queries:
#           Also generate all 22 templates x 20 seeds and validate each
#           query (expensive: can take 30-60+ minutes).
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
            echo "--with-queries: also generate and validate TPC-H queries (expensive)."
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

DB="${TPCH_DB}"
WORK_DIR="/tmp/tpch-build"
DATA_DIR="/tmp/tpch-data"

echo "=================================="
echo "TPC-H 1GB Setup"
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

# ── Step 3: Clone tpch-dbgen ──────────────────────────────────────────────────
echo ""
echo "-- Step 3: Download tpch-dbgen"
git clone https://github.com/electrum/tpch-dbgen.git "${WORK_DIR}"

# ── Step 4: Build dbgen ───────────────────────────────────────────────────────
echo ""
echo "-- Step 4: Build dbgen"
cd "${WORK_DIR}"
make

# ── Step 5: Generate data (scale factor 1 = 1 GB) ────────────────────────────
echo ""
echo "-- Step 5: Generate data (SF=1)"
./dbgen -s 1 -f

# ── Step 6: Move .tbl files ───────────────────────────────────────────────────
echo ""
echo "-- Step 6: Move data files"
mv ./*.tbl "${DATA_DIR}/"

# ── Step 7: Fix trailing pipe delimiter ───────────────────────────────────────
echo ""
echo "-- Step 7: Fix trailing delimiter in TPC-H files"
for f in "${DATA_DIR}"/*.tbl; do
    sed -i 's/|$//' "$f"
done

# ── Step 8: (Re)create database ───────────────────────────────────────────────
echo ""
echo "-- Step 8: Create database '${DB}'"
pg_ensure_running

if db_exists "${DB}"; then
    echo "  [WARN] Database '${DB}' already exists — dropping and recreating"
    $PSQL -c "
        SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity
        WHERE datname = '${DB}' AND pid <> pg_backend_pid();
    " || true
    $PSQL -c "DROP DATABASE IF EXISTS ${DB};"
fi
$PG_BIN/createdb "${DB}"
echo "  [OK] Database '${DB}' created"

# ── Step 9: Create schema ─────────────────────────────────────────────────────
echo ""
echo "-- Step 9: Create schema"

$PSQL "${DB}" <<'SQL'
CREATE TABLE region (
    r_regionkey int,
    r_name      char(25),
    r_comment   varchar(152)
);

CREATE TABLE nation (
    n_nationkey int,
    n_name      char(25),
    n_regionkey int,
    n_comment   varchar(152)
);

CREATE TABLE part (
    p_partkey     int,
    p_name        varchar(55),
    p_mfgr        char(25),
    p_brand       char(10),
    p_type        varchar(25),
    p_size        int,
    p_container   char(10),
    p_retailprice decimal,
    p_comment     varchar(23)
);

CREATE TABLE supplier (
    s_suppkey   int,
    s_name      char(25),
    s_address   varchar(40),
    s_nationkey int,
    s_phone     char(15),
    s_acctbal   decimal,
    s_comment   varchar(101)
);

CREATE TABLE partsupp (
    ps_partkey    int,
    ps_suppkey    int,
    ps_availqty   int,
    ps_supplycost decimal,
    ps_comment    varchar(199)
);

CREATE TABLE customer (
    c_custkey    int,
    c_name       varchar(25),
    c_address    varchar(40),
    c_nationkey  int,
    c_phone      char(15),
    c_acctbal    decimal,
    c_mktsegment char(10),
    c_comment    varchar(117)
);

CREATE TABLE orders (
    o_orderkey      bigint,
    o_custkey       int,
    o_orderstatus   char(1),
    o_totalprice    decimal,
    o_orderdate     date,
    o_orderpriority char(15),
    o_clerk         char(15),
    o_shippriority  int,
    o_comment       varchar(79)
);

CREATE TABLE lineitem (
    l_orderkey      bigint,
    l_partkey       int,
    l_suppkey       int,
    l_linenumber    int,
    l_quantity      decimal,
    l_extendedprice decimal,
    l_discount      decimal,
    l_tax           decimal,
    l_returnflag    char(1),
    l_linestatus    char(1),
    l_shipdate      date,
    l_commitdate    date,
    l_receiptdate   date,
    l_shipinstruct  char(25),
    l_shipmode      char(10),
    l_comment       varchar(44)
);
SQL

echo "  [OK] Schema created"

# ── Step 10: Bulk-load data ───────────────────────────────────────────────────
echo ""
echo "-- Step 10: Load data"
for t in region nation part supplier partsupp customer orders lineitem; do
    echo "  Loading ${t}..."
    $PSQL "${DB}" -c "\copy ${t} FROM '${DATA_DIR}/${t}.tbl' DELIMITER '|'"
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
    echo "-- Step 14: Generate query seeds (22 templates x 20 seeds)"

    QUERY_DIR="${EXPERIMENT_DIR}/tpch/queries"
    TMPQUERY_DIR=$(mktemp -d /tmp/tpch-queries-XXXXXX)
    chmod 755 "${TMPQUERY_DIR}"
    mkdir -p "${QUERY_DIR}"

    # 20 diverse random seeds
    SEEDS=(42 17 99 7 1337 2024 55 123 456 789 321 654 987 111 222 333 444 555 666 777)

    # All 22 TPC-H query templates
    for tmpl in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do
        for seed in "${SEEDS[@]}"; do
            fname="q$(printf '%02d' "${tmpl}")_s${seed}.sql"
            (
                cd "${WORK_DIR}"
                DSS_QUERY=./queries ./qgen -s 1 -r "${seed}" "${tmpl}" 2>/dev/null
            ) \
            | grep -v "^--" \
            | grep -v "^where rownum" \
            | sed "s/interval '\([0-9]*\)' day ([0-9]\+)/interval '\1 days'/g" \
            | sed '/^[[:space:]]*$/d' \
            > "${TMPQUERY_DIR}/${fname}"
            # Remove empty files (template failed to generate)
            [ -s "${TMPQUERY_DIR}/${fname}" ] || rm -f "${TMPQUERY_DIR}/${fname}"
        done
        echo "  Q${tmpl} done (${#SEEDS[@]} variants)"
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
echo "TPC-H Setup Completed"
echo "Database : ${DB}"
echo "Queries  : ${EXPERIMENT_DIR}/tpch/queries"
echo "=================================="
