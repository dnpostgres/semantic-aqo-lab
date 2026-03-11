#!/usr/bin/env bash
# =============================================================================
# bench_runner.sh — Shared benchmark runner for AQO experiments
#
# Usage: source this file, then call:
#   run_phase <db> <query_dir> <results_dir> <mode> <iterations>
#
# Modes: disabled, learn, frozen
# =============================================================================

set -euo pipefail

# ── run a single phase (disabled / learn / frozen) ──────────────────────────
run_phase() {
    local db="$1"
    local query_dir="$2"
    local results_dir="$3"
    local mode="$4"
    local iters="$5"

    local csv="${results_dir}/${mode}_report.csv"
    local stat_csv="${results_dir}/${mode}_aqo_query_stat.csv"
    local err_csv="${results_dir}/${mode}_cardinality_error.csv"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Phase: ${mode^^}   DB: $db   Iterations: $iters"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    mkdir -p "$results_dir"

    # Configure AQO mode
    local aqo_mode
    case "$mode" in
        disabled)  aqo_mode="disabled" ;;
        learn)     aqo_mode="learn" ;;
        frozen)    aqo_mode="controlled" ;;
        *)         echo "Unknown mode: $mode"; return 1 ;;
    esac

    # Write GUC setup to temp file
    local guc_file
    guc_file=$(mktemp /tmp/aqo_gucs.XXXXXX.sql)
    cat > "$guc_file" <<GUCSQL
SET aqo.mode = '${aqo_mode}';
SET aqo.join_threshold = ${AQO_JOIN_THRESHOLD:-0};
SET aqo.force_collect_stat = 'on';
GUCSQL

    if [ "$mode" = "learn" ]; then
        cat >> "$guc_file" <<GUCSQL
SET max_parallel_workers_per_gather = ${LEARN_PARALLEL_WORKERS:-0};
GUCSQL
    elif [ "$mode" = "frozen" ]; then
        cat >> "$guc_file" <<GUCSQL
SET max_parallel_workers_per_gather = ${FROZEN_PARALLEL_WORKERS:-2};
GUCSQL
    fi

    # CSV header
    echo "iteration,query_name,execution_time_ms,planning_time_ms,query_hash" > "$csv"

    # Run iterations
    for (( i=1; i<=iters; i++ )); do
        echo "  ── Iteration $i/$iters ──"
        for qfile in "$query_dir"/*.sql; do
            [ -f "$qfile" ] || continue
            local qname
            qname=$(basename "$qfile" .sql)

            # Build explain query
            local tmpq
            tmpq=$(mktemp /tmp/aqo_q.XXXXXX.sql)
            cat "$guc_file" > "$tmpq"
            echo "EXPLAIN (ANALYZE, VERBOSE, FORMAT JSON) " >> "$tmpq"
            cat "$qfile" >> "$tmpq"

            # Execute and parse JSON result
            local result
            result=$($PSQL -d "$db" -t -A -f "$tmpq" 2>/dev/null) || {
                echo "    SKIP $qname (error)"
                rm -f "$tmpq"
                continue
            }
            rm -f "$tmpq"

            local exec_time plan_time query_hash
            exec_time=$(echo "$result" | grep -oP '"Execution Time": \K[0-9.]+' | head -1)
            plan_time=$(echo "$result" | grep -oP '"Planning Time": \K[0-9.]+' | head -1)
            query_hash=$(echo "$result" | grep -oP '"Query Identifier": \K[-0-9]+' | head -1)

            exec_time=${exec_time:-0}
            plan_time=${plan_time:-0}
            query_hash=${query_hash:-0}

            echo "$i,$qname,$exec_time,$plan_time,$query_hash" >> "$csv"
            printf "    %-20s  exec=%8s ms  plan=%7s ms\n" "$qname" "$exec_time" "$plan_time"
        done

        # Capture cardinality error after each learn iteration
        if [ "$mode" = "learn" ]; then
            local iter_err
            iter_err=$($PSQL -d "$db" -t -A -c \
                "SELECT error FROM aqo_cardinality_error(true)" 2>/dev/null || echo "")
            if [ -n "$iter_err" ]; then
                echo "$i,$iter_err" >> "${results_dir}/${mode}_err_iter.csv"
            fi
        fi
    done

    rm -f "$guc_file"

    # Export aqo_query_stat
    echo "  Exporting aqo_query_stat → $stat_csv"
    $PSQL -d "$db" -c "\copy (SELECT * FROM aqo_query_stat) TO '$stat_csv' DELIMITER ',' CSV HEADER" 2>/dev/null || true

    # Export cardinality error summary
    echo "  Exporting cardinality errors → $err_csv"
    $PSQL -d "$db" -c "\copy (SELECT * FROM aqo_cardinality_error(true)) TO '$err_csv' DELIMITER ',' CSV HEADER" 2>/dev/null || true

    echo "  Phase ${mode^^} complete. Results in $results_dir"
}

# ── reset AQO state ─────────────────────────────────────────────────────────
reset_aqo() {
    local db="$1"
    echo "  Resetting AQO state in $db..."
    $PSQL -d "$db" -c "SELECT aqo_reset();" 2>/dev/null || true
    $PSQL -d "$db" -c "SELECT aqo_cleanup();" 2>/dev/null || true
}

# ── ensure AQO extension is installed ────────────────────────────────────────
ensure_aqo() {
    local db="$1"
    $PSQL -d "$db" -c "CREATE EXTENSION IF NOT EXISTS aqo;" 2>/dev/null || true
}
