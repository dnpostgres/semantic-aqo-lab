#!/usr/bin/env bash
# =============================================================================
# setup-all.sh — Complete Bootstrap
#
# Usage:
#   bash scripts/setup-all.sh [--benchmarks job,stats,tpch,tpcds] [--with-queries]
#
# Flow:
#   1. env/00-system-deps.sh       Install OS packages
#   2. env/01-build-postgres.sh    Build PG 15.15, init cluster
#   3. env/02-build-saqo.sh        Build semantic AQO extension, load embeddings
#   4. env/03-build-std-aqo.sh     Build standard AQO for comparison
#   5. For each selected benchmark: db/setup-<bench>.sh [--with-queries if passed]
#   6. Print summary
#
# Default benchmarks: tpch tpcds job stats (all four).
# --with-queries: passed through to each db/setup-<bench>.sh (expensive;
#                 almost never needed — pre-existing queries are used instead).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.env"
source "${SCRIPTS_DIR}/lib/common.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────
BENCHMARKS="tpch,tpcds,job,stats"
WITH_QUERIES=false

for arg in "$@"; do
    case "${arg}" in
        --benchmarks=*)
            BENCHMARKS="${arg#--benchmarks=}" ;;
        --benchmarks)
            echo "[ERROR] --benchmarks requires a value (e.g. --benchmarks=job,stats)" >&2
            exit 1 ;;
        --with-queries)
            WITH_QUERIES=true ;;
        --help|-h)
            echo "Usage: bash $(basename "$0") [--benchmarks job,stats,tpch,tpcds] [--with-queries]"
            echo ""
            echo "Options:"
            echo "  --benchmarks LIST  Comma-separated list of benchmarks to set up"
            echo "                     (default: tpch,tpcds,job,stats)"
            echo "  --with-queries     Also generate/extract and validate queries"
            echo "                     (expensive; skip unless you have no pre-existing queries)"
            echo ""
            echo "Steps performed:"
            echo "  1. env/00-system-deps.sh"
            echo "  2. env/01-build-postgres.sh"
            echo "  3. env/02-build-saqo.sh"
            echo "  4. env/03-build-std-aqo.sh"
            echo "  5. db/setup-<bench>.sh  [for each selected benchmark]"
            exit 0 ;;
        *)
            echo "[ERROR] Unknown argument: ${arg}" >&2
            echo "Run with --help for usage." >&2
            exit 1 ;;
    esac
done

# Convert comma-separated list to array
IFS=',' read -ra BENCH_LIST <<< "${BENCHMARKS}"

# Validate benchmark names
for b in "${BENCH_LIST[@]}"; do
    case "${b}" in
        tpch|tpcds|job|stats) ;;
        *)
            echo "[ERROR] Unknown benchmark: '${b}'" >&2
            echo "  Valid values: tpch, tpcds, job, stats" >&2
            exit 1 ;;
    esac
done

WITH_QUERIES_FLAG=""
[ "${WITH_QUERIES}" = "true" ] && WITH_QUERIES_FLAG="--with-queries"

# ── Banner ────────────────────────────────────────────────────────────────────
echo "============================================================"
echo "  Semantic AQO -- Full Bootstrap"
echo "  Benchmarks  : ${BENCHMARKS}"
echo "  With queries: ${WITH_QUERIES}"
echo "  Date        : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

# Track timing
_start=$SECONDS
_total_steps=$(( 4 + ${#BENCH_LIST[@]} ))

# ── Step 1: System dependencies ───────────────────────────────────────────────
echo "============================================================"
echo "  Step 1/${_total_steps}: System dependencies"
echo "============================================================"
bash "${SCRIPTS_DIR}/env/00-system-deps.sh"
echo "[OK] System dependencies installed"
echo ""

# ── Step 2: Build PostgreSQL 15.15 ────────────────────────────────────────────
echo "============================================================"
echo "  Step 2/${_total_steps}: Build PostgreSQL 15.15"
echo "============================================================"
bash "${SCRIPTS_DIR}/env/01-build-postgres.sh"
echo "[OK] PostgreSQL built and cluster initialized"
echo ""

# ── Step 3: Build semantic AQO extension ──────────────────────────────────────
echo "============================================================"
echo "  Step 3/${_total_steps}: Build semantic AQO extension"
echo "============================================================"
bash "${SCRIPTS_DIR}/env/02-build-saqo.sh"
echo "[OK] Semantic AQO extension built and embeddings loaded"
echo ""

# ── Step 4: Build standard AQO ────────────────────────────────────────────────
echo "============================================================"
echo "  Step 4/${_total_steps}: Build standard AQO"
echo "============================================================"
bash "${SCRIPTS_DIR}/env/03-build-std-aqo.sh"
echo "[OK] Standard AQO built (aqo_std.so ready)"
echo ""

# ── Step 5+: Set up each benchmark database ───────────────────────────────────
_bench_step=5
for bench in "${BENCH_LIST[@]}"; do
    echo "============================================================"
    echo "  Step ${_bench_step}/${_total_steps}: DB setup -- ${bench}"
    echo "============================================================"

    SETUP_SCRIPT="${SCRIPTS_DIR}/db/setup-${bench}.sh"
    if [ ! -f "${SETUP_SCRIPT}" ]; then
        echo "[ERROR] Setup script not found: ${SETUP_SCRIPT}" >&2
        exit 1
    fi

    bash "${SETUP_SCRIPT}" ${WITH_QUERIES_FLAG}
    echo "[OK] ${bench} database ready"
    echo ""

    _bench_step=$((_bench_step+1))
done

# ── Summary ───────────────────────────────────────────────────────────────────
_elapsed=$(( SECONDS - _start ))
_mins=$(( _elapsed / 60 ))
_secs=$(( _elapsed % 60 ))

echo "============================================================"
echo "  Bootstrap complete in ${_mins}m ${_secs}s"
echo ""
echo "  Environment:"
echo "    PostgreSQL : ${PG_BIN}/postgres"
echo "    PGDATA     : ${PG_DATA}"
echo "    aqo_std.so : ${PG_LIB}/aqo_std.so"
echo "    aqo_sem.so : ${PG_LIB}/aqo_semantic.so"
echo ""
echo "  Databases set up:"
for bench in "${BENCH_LIST[@]}"; do
    case "${bench}" in
        tpch)  echo "    tpch  -> ${TPCH_DB}" ;;
        tpcds) echo "    tpcds -> ${TPCDS_DB}" ;;
        job)   echo "    job   -> ${JOB_DB}" ;;
        stats) echo "    stats -> ${STATS_DB}" ;;
    esac
done
echo ""
echo "  Ready to run experiments:"
echo "    bash scripts/experiment/run.sh --benchmark job   --iterations 15"
echo "    bash scripts/experiment/run.sh --benchmark stats --iterations 15"
echo "    bash scripts/experiment/run.sh --benchmark tpch  --iterations 15"
echo "    bash scripts/experiment/run.sh --benchmark tpcds --iterations 15"
echo "============================================================"
