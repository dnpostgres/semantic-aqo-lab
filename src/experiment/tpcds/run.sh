#!/usr/bin/env bash
# =============================================================================
# TPC-DS Experiment Runner
#
# Runs 3 phases: disabled → learn → frozen
# Results written to experiment/tpcds/results/<timestamp>/
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$EXPERIMENT_DIR/config.sh"
source "$EXPERIMENT_DIR/lib/bench_runner.sh"

DB="${TPCDS_DB}"
QUERY_DIR="$SCRIPT_DIR/queries"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$SCRIPT_DIR/results/${TIMESTAMP}"

echo "╔═══════════════════════════════════════════════════════╗"
echo "║            TPC-DS AQO Experiment                     ║"
echo "║  Database : $DB"
echo "║  Queries  : $QUERY_DIR"
echo "║  Results  : $RESULTS_DIR"
echo "║  Phases   : disabled($DISABLED_ITERS) → learn($LEARN_ITERS) → frozen($FROZEN_ITERS)"
echo "╚═══════════════════════════════════════════════════════╝"

mkdir -p "$RESULTS_DIR"

# Ensure AQO is installed
ensure_aqo "$DB"

# Phase 1: Disabled (baseline — no AQO)
reset_aqo "$DB"
run_phase "$DB" "$QUERY_DIR" "$RESULTS_DIR" disabled "$DISABLED_ITERS"

# Phase 2: Learn (AQO collects stats and learns)
reset_aqo "$DB"
run_phase "$DB" "$QUERY_DIR" "$RESULTS_DIR" learn "$LEARN_ITERS"

# Phase 3: Frozen (AQO uses learned models, no further learning)
run_phase "$DB" "$QUERY_DIR" "$RESULTS_DIR" frozen "$FROZEN_ITERS"

echo ""
echo "════════════════════════════════════════════════════════"
echo "  TPC-DS experiment complete."
echo "  Results: $RESULTS_DIR"
echo "════════════════════════════════════════════════════════"
