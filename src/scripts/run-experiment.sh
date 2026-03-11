#!/usr/bin/env bash
# =============================================================================
# run-experiment.sh — Full AQO Experiment Pipeline
#
# Controls the entire flow:
#   1. Ensure databases exist (load TPC-H / TPC-DS if needed)
#   2. Run TPC-H experiment (disabled → learn → frozen)
#   3. Run TPC-DS experiment (disabled → learn → frozen)
#   4. Analyze results
#
# Usage:
#   ./scripts/run-experiment.sh [--tpch-only | --tpcds-only] [--skip-load]
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPERIMENT_DIR="$REPO_ROOT/experiment"
SCRIPTS_DIR="$REPO_ROOT/scripts"

source "$EXPERIMENT_DIR/config.sh"

# ── Parse arguments ──────────────────────────────────────────────────────────
RUN_TPCH=true
RUN_TPCDS=true
SKIP_LOAD=false

for arg in "$@"; do
    case "$arg" in
        --tpch-only)   RUN_TPCDS=false ;;
        --tpcds-only)  RUN_TPCH=false ;;
        --skip-load)   SKIP_LOAD=true ;;
        --help|-h)
            echo "Usage: $0 [--tpch-only | --tpcds-only] [--skip-load]"
            echo ""
            echo "Options:"
            echo "  --tpch-only    Run only TPC-H benchmark"
            echo "  --tpcds-only   Run only TPC-DS benchmark"
            echo "  --skip-load    Skip database loading (assume DBs exist)"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║         AQO Full Experiment Pipeline                     ║"
echo "║                                                          ║"
echo "║  TPC-H  : $([ "$RUN_TPCH" = true ] && echo "YES" || echo "SKIP")"
echo "║  TPC-DS : $([ "$RUN_TPCDS" = true ] && echo "YES" || echo "SKIP")"
echo "║  Skip DB: $([ "$SKIP_LOAD" = true ] && echo "YES" || echo "NO")"
echo "╚═══════════════════════════════════════════════════════════╝"

# ── Step 1: Ensure databases are loaded ──────────────────────────────────────
db_exists() {
    $PSQL -lqt | cut -d \| -f 1 | grep -qw "$1"
}

if [ "$SKIP_LOAD" = false ]; then
    echo ""
    echo "━━━ Step 1: Database Setup ━━━"

    if [ "$RUN_TPCH" = true ] && ! db_exists "$TPCH_DB"; then
        echo "  Loading TPC-H database..."
        if [ -f "$SCRIPTS_DIR/databases/01-setup-tpch-1gb.sh" ]; then
            bash "$SCRIPTS_DIR/databases/01-setup-tpch-1gb.sh"
        else
            echo "  ERROR: $SCRIPTS_DIR/databases/01-setup-tpch-1gb.sh not found"
            exit 1
        fi
    elif [ "$RUN_TPCH" = true ]; then
        echo "  TPC-H database '$TPCH_DB' already exists."
    fi

    if [ "$RUN_TPCDS" = true ] && ! db_exists "$TPCDS_DB"; then
        echo "  Loading TPC-DS database..."
        if [ -f "$SCRIPTS_DIR/databases/02-setup-tpcds-1gb.sh" ]; then
            bash "$SCRIPTS_DIR/databases/02-setup-tpcds-1gb.sh"
        else
            echo "  ERROR: $SCRIPTS_DIR/databases/02-setup-tpcds-1gb.sh not found"
            exit 1
        fi
    elif [ "$RUN_TPCDS" = true ]; then
        echo "  TPC-DS database '$TPCDS_DB' already exists."
    fi
else
    echo ""
    echo "━━━ Step 1: Database Setup — SKIPPED ━━━"
fi

# ── Step 2: Run TPC-H ───────────────────────────────────────────────────────
TPCH_RESULTS=""
if [ "$RUN_TPCH" = true ]; then
    echo ""
    echo "━━━ Step 2: TPC-H Benchmark ━━━"
    chmod +x "$EXPERIMENT_DIR/tpch/run.sh"
    bash "$EXPERIMENT_DIR/tpch/run.sh"
    # Find latest results directory
    TPCH_RESULTS=$(ls -td "$EXPERIMENT_DIR/tpch/results"/*/ 2>/dev/null | head -1)
fi

# ── Step 3: Run TPC-DS ──────────────────────────────────────────────────────
TPCDS_RESULTS=""
if [ "$RUN_TPCDS" = true ]; then
    echo ""
    echo "━━━ Step 3: TPC-DS Benchmark ━━━"
    chmod +x "$EXPERIMENT_DIR/tpcds/run.sh"
    bash "$EXPERIMENT_DIR/tpcds/run.sh"
    TPCDS_RESULTS=$(ls -td "$EXPERIMENT_DIR/tpcds/results"/*/ 2>/dev/null | head -1)
fi

# ── Step 4: Analyze ─────────────────────────────────────────────────────────
echo ""
echo "━━━ Step 4: Analysis ━━━"

if [ -n "$TPCH_RESULTS" ]; then
    echo ""
    echo "── TPC-H Analysis ──"
    python3 "$EXPERIMENT_DIR/analyze.py" "$TPCH_RESULTS"
fi

if [ -n "$TPCDS_RESULTS" ]; then
    echo ""
    echo "── TPC-DS Analysis ──"
    python3 "$EXPERIMENT_DIR/analyze.py" "$TPCDS_RESULTS"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Full experiment pipeline complete."
[ -n "$TPCH_RESULTS" ] && echo "  TPC-H results : $TPCH_RESULTS"
[ -n "$TPCDS_RESULTS" ] && echo "  TPC-DS results: $TPCDS_RESULTS"
echo "════════════════════════════════════════════════════════════"
