#!/usr/bin/env bash
# =============================================================================
# experiment/run.sh — Unified Experiment Entry Point
#
# Usage:
#   bash scripts/experiment/run.sh \
#       --benchmark <job|stats|tpch|tpcds> \
#       [--iterations N]              (default: 15)
#       [--modes MODE1,MODE2,...]     (default: no_aqo,standard_aqo,semantic_aqo)
#       [--force]                     (discard checkpoints, re-run all phases)
#       [--results-dir DIR]           (override default results directory)
#
# What this script does:
#   1. Source config.env
#   2. Resolve benchmark -> DB name, query dir, results dir
#   3. Preflight checks (fail-stop):
#      - PostgreSQL is running
#      - Target database exists
#      - Query directory exists and has .sql files
#      - aqo_std.so and aqo_semantic.so both exist
#      - Active AQO variant verified before each phase (via verify_aqo_variant)
#   4. Call runner.py with resolved arguments
#   5. Call analyze.py for figure generation
#
# What this script does NOT do:
#   - No DB creation
#   - No AQO extension install
#   - No initdb
#   - No query generation
#
# Run db/setup-<bench>.sh first to prepare the database.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"
source "${SCRIPTS_DIR}/lib/common.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────
BENCHMARK=""
ITERATIONS=15
MODES=""
FORCE=false
RESULTS_DIR_OVERRIDE=""

usage() {
    echo "Usage: bash $(basename "$0") --benchmark <job|stats|tpch|tpcds>"
    echo "       [--iterations N] [--modes MODE1,MODE2,...] [--force] [--results-dir DIR]"
    echo ""
    echo "Benchmarks:"
    echo "  job    JOB / IMDB (113 hand-written queries)"
    echo "  stats  STATS-CEB (146 queries)"
    echo "  tpch   TPC-H (22 templates, multiple seeds)"
    echo "  tpcds  TPC-DS (99 templates, multiple seeds)"
    echo ""
    echo "Modes (default: all three):"
    echo "  no_aqo, standard_aqo, semantic_aqo"
    echo ""
    echo "Options:"
    echo "  --iterations N     Iterations per mode (default: 15)"
    echo "  --modes M1,M2,...  Comma-separated subset of modes to run"
    echo "  --force            Discard existing checkpoints and re-run everything"
    echo "  --results-dir DIR  Override default results directory"
    echo ""
    echo "Prerequisites:"
    echo "  bash scripts/db/setup-<bench>.sh   (run once to set up the database)"
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --benchmark)
            [ $# -ge 2 ] || { echo "[ERROR] --benchmark requires an argument" >&2; exit 1; }
            BENCHMARK="$2"; shift 2 ;;
        --iterations)
            [ $# -ge 2 ] || { echo "[ERROR] --iterations requires an argument" >&2; exit 1; }
            ITERATIONS="$2"; shift 2 ;;
        --modes)
            [ $# -ge 2 ] || { echo "[ERROR] --modes requires an argument" >&2; exit 1; }
            MODES="$2"; shift 2 ;;
        --force)
            FORCE=true; shift ;;
        --results-dir)
            [ $# -ge 2 ] || { echo "[ERROR] --results-dir requires an argument" >&2; exit 1; }
            RESULTS_DIR_OVERRIDE="$2"; shift 2 ;;
        --help|-h)
            usage ;;
        *)
            echo "[ERROR] Unknown argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1 ;;
    esac
done

if [ -z "${BENCHMARK}" ]; then
    echo "[ERROR] --benchmark is required." >&2
    echo "Run with --help for usage." >&2
    exit 1
fi

# ── Resolve benchmark -> DB, query dir, results dir ───────────────────────────
case "${BENCHMARK}" in
    job)
        BENCH_DB="${JOB_DB}"
        BENCH_QUERY_DIR="${EXPERIMENT_DIR}/job/queries"
        BENCH_RESULTS_DIR="${EXPERIMENT_DIR}/job/results"
        BENCH_LABEL="JOB"
        ;;
    stats)
        BENCH_DB="${STATS_DB}"
        BENCH_QUERY_DIR="${EXPERIMENT_DIR}/stats/queries"
        BENCH_RESULTS_DIR="${EXPERIMENT_DIR}/stats/results"
        BENCH_LABEL="STATS-CEB"
        ;;
    tpch)
        BENCH_DB="${TPCH_DB}"
        BENCH_QUERY_DIR="${EXPERIMENT_DIR}/tpch/queries"
        BENCH_RESULTS_DIR="${EXPERIMENT_DIR}/tpch/results"
        BENCH_LABEL="TPC-H"
        ;;
    tpcds)
        BENCH_DB="${TPCDS_DB}"
        BENCH_QUERY_DIR="${EXPERIMENT_DIR}/tpcds/queries"
        BENCH_RESULTS_DIR="${EXPERIMENT_DIR}/tpcds/results"
        BENCH_LABEL="TPC-DS"
        ;;
    *)
        echo "[ERROR] Unknown benchmark: '${BENCHMARK}'" >&2
        echo "Valid values: job, stats, tpch, tpcds" >&2
        exit 1
        ;;
esac

# Apply results-dir override if provided
if [ -n "${RESULTS_DIR_OVERRIDE}" ]; then
    BENCH_RESULTS_DIR="${RESULTS_DIR_OVERRIDE}"
fi

# ── Print run plan ─────────────────────────────────────────────────────────────
echo "============================================================"
echo "  Experiment: ${BENCH_LABEL}"
echo "  DB        : ${BENCH_DB}"
echo "  Queries   : ${BENCH_QUERY_DIR}"
echo "  Results   : ${BENCH_RESULTS_DIR}"
echo "  Iterations: ${ITERATIONS}"
echo "  Modes     : ${MODES:-no_aqo, standard_aqo, semantic_aqo (all)}"
echo "  Force     : ${FORCE}"
echo "============================================================"

# ── Preflight checks (fail-stop) ──────────────────────────────────────────────
echo ""
echo "-- Preflight checks"

# 1. PostgreSQL must be running
echo "  Checking PostgreSQL is running..."
if ! sudo -u postgres "${PG_BIN}/pg_ctl" -D "${PG_DATA}" status >/dev/null 2>&1; then
    echo "[ERROR] PostgreSQL is not running." >&2
    echo "  Start it with: sudo -u postgres ${PG_BIN}/pg_ctl -D ${PG_DATA} start" >&2
    exit 1
fi
echo "  [OK] PostgreSQL is running"

# 2. Target database must exist
echo "  Checking database '${BENCH_DB}' exists..."
if ! db_exists "${BENCH_DB}"; then
    echo "[ERROR] Database '${BENCH_DB}' does not exist." >&2
    echo "  Run: bash ${SCRIPTS_DIR}/db/setup-${BENCHMARK}.sh" >&2
    exit 1
fi
echo "  [OK] Database '${BENCH_DB}' exists"

# 3. Query directory must exist and contain .sql files
echo "  Checking query directory..."
if [ ! -d "${BENCH_QUERY_DIR}" ]; then
    echo "[ERROR] Query directory does not exist: ${BENCH_QUERY_DIR}" >&2
    echo "  Run: bash ${SCRIPTS_DIR}/db/setup-${BENCHMARK}.sh --with-queries" >&2
    exit 1
fi
_qcount=$(ls "${BENCH_QUERY_DIR}"/*.sql 2>/dev/null | wc -l)
if [ "${_qcount}" -eq 0 ]; then
    echo "[ERROR] No .sql files found in: ${BENCH_QUERY_DIR}" >&2
    echo "  Run: bash ${SCRIPTS_DIR}/db/setup-${BENCHMARK}.sh --with-queries" >&2
    exit 1
fi
echo "  [OK] ${_qcount} query files found"

# 4. AQO variant .so files must exist
AQO_STD_SO="${PG_LIB}/aqo_std.so"
AQO_SEM_SO="${PG_LIB}/aqo_semantic.so"
echo "  Checking AQO variant binaries..."
_missing_so=false
if [ ! -f "${AQO_STD_SO}" ]; then
    echo "  [ERROR] Missing: ${AQO_STD_SO}" >&2
    _missing_so=true
fi
if [ ! -f "${AQO_SEM_SO}" ]; then
    echo "  [ERROR] Missing: ${AQO_SEM_SO}" >&2
    _missing_so=true
fi
if [ "${_missing_so}" = "true" ]; then
    echo "[ERROR] AQO variant binaries are missing. Run: bash ${SCRIPTS_DIR}/env/04-build-std-aqo.sh" >&2
    exit 1
fi
echo "  [OK] Both AQO variant binaries exist"

# 5. Verify PG is responsive and AQO is loaded (aqo.so shared_preload_libraries)
echo "  Checking AQO extension is loadable..."
if ! $PSQL -d "${BENCH_DB}" -c "CREATE EXTENSION IF NOT EXISTS aqo;" >/dev/null 2>&1; then
    echo "[ERROR] Cannot load AQO extension in '${BENCH_DB}'." >&2
    echo "  Check: shared_preload_libraries = 'aqo' in ${PG_DATA}/postgresql.conf" >&2
    exit 1
fi
echo "  [OK] AQO extension loadable in '${BENCH_DB}'"

echo ""
echo "  [OK] All preflight checks passed"

# ── Prepare results directory ─────────────────────────────────────────────────
mkdir -p "${BENCH_RESULTS_DIR}"

# ── Build runner.py arguments ──────────────────────────────────────────────────
RUNNER_ARGS=(
    "${BENCH_DB}"
    "${BENCH_QUERY_DIR}"
    "${BENCH_RESULTS_DIR}"
    "--iterations" "${ITERATIONS}"
)

[ "${FORCE}" = "true" ]   && RUNNER_ARGS+=("--force")
[ -n "${MODES}" ]         && RUNNER_ARGS+=("--modes" "${MODES}")

# ── Run experiment via runner.py ───────────────────────────────────────────────
echo ""
echo "-- Running experiment"
echo "   python3 ${EXPERIMENT_DIR}/runner.py ${RUNNER_ARGS[*]}"
echo ""

# Export SWITCH_AQO so runner.py finds the right switch script
export SWITCH_AQO="${SCRIPTS_DIR}/env/switch-aqo.sh"
export PSQL

python3 "${EXPERIMENT_DIR}/runner.py" "${RUNNER_ARGS[@]}"
_runner_rc=$?

if [ ${_runner_rc} -ne 0 ]; then
    echo "[ERROR] runner.py exited with code ${_runner_rc}" >&2
    exit ${_runner_rc}
fi

# ── Generate figures via analyze.py ───────────────────────────────────────────
echo ""
echo "-- Generating figures"
python3 "${EXPERIMENT_DIR}/analyze.py" \
    "${BENCH_RESULTS_DIR}" \
    --title "${BENCH_LABEL}"

echo ""
echo "============================================================"
echo "  Experiment complete."
echo "  Benchmark : ${BENCH_LABEL}"
echo "  Results   : ${BENCH_RESULTS_DIR}"
echo "============================================================"
