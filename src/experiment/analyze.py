#!/usr/bin/env python3
"""
analyze.py — Analyze AQO experiment results.

Usage:
    python3 analyze.py <results_dir>

Reads CSV files from a benchmark results directory and produces:
  - Summary statistics (mean/median/std exec time per query per phase)
  - Speedup ratios (disabled vs frozen)
  - Per-iteration execution time plots
  - Learning curve (cardinality error convergence)
"""

import sys
import os
import csv
from pathlib import Path
from collections import defaultdict

def load_report(csv_path):
    """Load a phase report CSV → list of dicts."""
    rows = []
    with open(csv_path, newline='') as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({
                'iteration': int(row['iteration']),
                'query': row['query_name'],
                'exec_time': float(row['execution_time_ms']),
                'plan_time': float(row['planning_time_ms']),
                'query_hash': row.get('query_hash', ''),
            })
    return rows


def compute_stats(rows):
    """Group by query, compute mean/median/std for exec_time."""
    from statistics import mean, median, stdev
    by_query = defaultdict(list)
    for r in rows:
        by_query[r['query']].append(r['exec_time'])

    stats = {}
    for q, times in sorted(by_query.items()):
        s = {
            'mean': mean(times),
            'median': median(times),
            'std': stdev(times) if len(times) > 1 else 0.0,
            'min': min(times),
            'max': max(times),
            'n': len(times),
        }
        stats[q] = s
    return stats


def print_phase_summary(phase_name, stats):
    """Pretty-print phase summary."""
    print(f"\n{'─'*72}")
    print(f"  Phase: {phase_name.upper()}")
    print(f"{'─'*72}")
    print(f"  {'Query':<20} {'Mean':>10} {'Median':>10} {'Std':>10} {'Min':>10} {'Max':>10} {'N':>5}")
    print(f"  {'─'*20} {'─'*10} {'─'*10} {'─'*10} {'─'*10} {'─'*10} {'─'*5}")

    total_mean = 0.0
    for q, s in sorted(stats.items()):
        print(f"  {q:<20} {s['mean']:>10.2f} {s['median']:>10.2f} {s['std']:>10.2f} {s['min']:>10.2f} {s['max']:>10.2f} {s['n']:>5}")
        total_mean += s['mean']

    print(f"  {'─'*20} {'─'*10}")
    print(f"  {'TOTAL':<20} {total_mean:>10.2f} ms (sum of means)")


def print_speedup(disabled_stats, frozen_stats):
    """Compare disabled baseline vs frozen (AQO-enabled)."""
    print(f"\n{'═'*72}")
    print(f"  SPEEDUP: Disabled → Frozen (AQO)")
    print(f"{'═'*72}")
    print(f"  {'Query':<20} {'Disabled':>12} {'Frozen':>12} {'Speedup':>10} {'Change':>10}")
    print(f"  {'─'*20} {'─'*12} {'─'*12} {'─'*10} {'─'*10}")

    total_disabled = 0.0
    total_frozen = 0.0
    improvements = 0
    regressions = 0

    all_queries = sorted(set(disabled_stats.keys()) | set(frozen_stats.keys()))
    for q in all_queries:
        d = disabled_stats.get(q, {}).get('mean', 0)
        f = frozen_stats.get(q, {}).get('mean', 0)
        total_disabled += d
        total_frozen += f

        if d > 0 and f > 0:
            speedup = d / f
            change_pct = ((d - f) / d) * 100
            marker = '↑' if change_pct > 0 else '↓'
            if change_pct > 1:
                improvements += 1
            elif change_pct < -1:
                regressions += 1
            print(f"  {q:<20} {d:>12.2f} {f:>12.2f} {speedup:>9.2f}x {change_pct:>+9.1f}% {marker}")
        else:
            print(f"  {q:<20} {d:>12.2f} {f:>12.2f} {'N/A':>10} {'N/A':>10}")

    print(f"  {'─'*20} {'─'*12} {'─'*12} {'─'*10}")
    if total_disabled > 0 and total_frozen > 0:
        overall = total_disabled / total_frozen
        overall_pct = ((total_disabled - total_frozen) / total_disabled) * 100
        print(f"  {'TOTAL':<20} {total_disabled:>12.2f} {total_frozen:>12.2f} {overall:>9.2f}x {overall_pct:>+9.1f}%")
    print(f"\n  Improved: {improvements}  |  Regressed: {regressions}  |  Total queries: {len(all_queries)}")


def print_learning_curve(learn_rows):
    """Show per-iteration total execution time during learning."""
    by_iter = defaultdict(float)
    for r in learn_rows:
        by_iter[r['iteration']] += r['exec_time']

    if not by_iter:
        return

    print(f"\n{'─'*72}")
    print(f"  LEARNING CURVE: Total execution time per iteration")
    print(f"{'─'*72}")

    iters = sorted(by_iter.keys())
    max_time = max(by_iter.values()) if by_iter else 1
    bar_width = 40

    for i in iters:
        t = by_iter[i]
        bar_len = int((t / max_time) * bar_width) if max_time > 0 else 0
        bar = '█' * bar_len + '░' * (bar_width - bar_len)
        print(f"  Iter {i:>3}: {bar} {t:>10.2f} ms")

    if len(iters) >= 2:
        first = by_iter[iters[0]]
        last = by_iter[iters[-1]]
        if first > 0:
            improvement = ((first - last) / first) * 100
            print(f"\n  First → Last: {first:.2f} → {last:.2f} ms ({improvement:+.1f}%)")


def write_summary_csv(results_dir, disabled_stats, frozen_stats):
    """Write a combined summary CSV for further processing."""
    out_path = os.path.join(results_dir, 'summary.csv')
    all_queries = sorted(set(disabled_stats.keys()) | set(frozen_stats.keys()))

    with open(out_path, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['query', 'disabled_mean_ms', 'disabled_median_ms',
                         'frozen_mean_ms', 'frozen_median_ms', 'speedup'])
        for q in all_queries:
            d_mean = disabled_stats.get(q, {}).get('mean', 0)
            d_med = disabled_stats.get(q, {}).get('median', 0)
            f_mean = frozen_stats.get(q, {}).get('mean', 0)
            f_med = frozen_stats.get(q, {}).get('median', 0)
            speedup = d_mean / f_mean if f_mean > 0 else 0
            writer.writerow([q, f'{d_mean:.2f}', f'{d_med:.2f}',
                            f'{f_mean:.2f}', f'{f_med:.2f}', f'{speedup:.3f}'])

    print(f"\n  Summary CSV written to: {out_path}")


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <results_dir>")
        sys.exit(1)

    results_dir = sys.argv[1]
    if not os.path.isdir(results_dir):
        print(f"Error: {results_dir} is not a directory")
        sys.exit(1)

    # Load phase reports
    phases = {}
    for mode in ['disabled', 'learn', 'frozen']:
        csv_path = os.path.join(results_dir, f'{mode}_report.csv')
        if os.path.exists(csv_path):
            phases[mode] = load_report(csv_path)
        else:
            print(f"  Warning: {csv_path} not found, skipping {mode} phase")

    if not phases:
        print("No report CSVs found.")
        sys.exit(1)

    print("╔═══════════════════════════════════════════════════════╗")
    print("║          AQO Experiment Analysis                     ║")
    print(f"║  Results: {results_dir:<43}║")
    print("╚═══════════════════════════════════════════════════════╝")

    # Per-phase summaries
    all_stats = {}
    for mode, rows in phases.items():
        stats = compute_stats(rows)
        all_stats[mode] = stats
        print_phase_summary(mode, stats)

    # Speedup comparison
    if 'disabled' in all_stats and 'frozen' in all_stats:
        print_speedup(all_stats['disabled'], all_stats['frozen'])
        write_summary_csv(results_dir, all_stats['disabled'], all_stats['frozen'])

    # Learning curve
    if 'learn' in phases:
        print_learning_curve(phases['learn'])

    print(f"\n{'═'*72}")
    print("  Analysis complete.")
    print(f"{'═'*72}")


if __name__ == '__main__':
    main()
