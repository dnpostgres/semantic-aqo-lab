#!/usr/bin/env bash
# =============================================================================
# JOB (Join Order Benchmark) Experiment Runner
#
# Runs 2 modes × N iterations: no_aqo (baseline) & with_aqo (semantic AQO)
# Results written to experiment/job/results/<timestamp>/
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$EXPERIMENT_DIR/config.sh"
source "$EXPERIMENT_DIR/lib/bench_runner.sh"

run_experiment "${JOB_DB}" "$SCRIPT_DIR/queries" "JOB"
