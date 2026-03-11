#!/usr/bin/env bash
# =============================================================================
# Experiment Configuration
# =============================================================================

export PSQL="sudo -u postgres /usr/local/pgsql/bin/psql"
export PGBIN="/usr/local/pgsql/bin"
export PGDATA="/usr/local/pgsql/data"

# Databases
export TPCH_DB="tpch"
export TPCDS_DB="tpcds"

# Iterations per phase
export DISABLED_ITERS=5
export LEARN_ITERS=15
export FROZEN_ITERS=5

# AQO settings
export AQO_JOIN_THRESHOLD=0

# Parallelism (disabled during learn for stability)
export LEARN_PARALLEL_WORKERS=0
export FROZEN_PARALLEL_WORKERS=2
