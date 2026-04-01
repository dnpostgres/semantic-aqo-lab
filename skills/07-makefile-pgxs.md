# Skill: Makefile & PGXS Build System

## Dual-Mode Makefile Template

Supports both in-tree (contrib/) and external (PGXS) builds:

```makefile
EXTENSION  = aqo
EXTVERSION = 1.6
PGFILEDESC = "AQO - Adaptive Query Optimization"
MODULE_big = aqo

# Object files
OBJS = $(WIN32RES) \
    aqo.o auto_tuning.o cardinality_estimation.o \
    machine_learning.o path_utils.o storage.o

# Regression tests (matched to sql/*.sql + expected/*.out)
REGRESS = test_disabled test_controlled test_learn

# TAP tests
TAP_TESTS = 1

# SQL migration files
DATA = aqo--1.0.sql aqo--1.0--1.1.sql aqo--1.6.sql

# Extra include paths (for dependent extensions)
fdw_srcdir = $(top_srcdir)/contrib/postgres_fdw
PG_CPPFLAGS += -I$(libpq_srcdir) -I$(fdw_srcdir)

# Custom test config
EXTRA_REGRESS_OPTS = --temp-config=$(top_srcdir)/$(subdir)/aqo.conf

# Install dependencies for tests
EXTRA_INSTALL = contrib/postgres_fdw contrib/pg_stat_statements

# Dual-mode: external PGXS or in-tree contrib
ifdef USE_PGXS
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/aqo
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
endif
```

## Key Variables

| Variable | Purpose |
|----------|---------|
| `MODULE_big` | Name of the `.so` shared library |
| `OBJS` | Object files (`.o`) to compile and link |
| `EXTENSION` | Extension name (must match `.control` file) |
| `DATA` | SQL migration files → installed to `$(sharedir)/extension/` |
| `REGRESS` | Regression test names (`sql/<name>.sql` + `expected/<name>.out`) |
| `TAP_TESTS = 1` | Enable TAP-based testing |
| `PG_CPPFLAGS` | Extra C preprocessor flags (include paths) |
| `PG_CFLAGS` | Extra C compiler flags |
| `EXTRA_INSTALL` | Other extensions to install before running tests |
| `EXTRA_REGRESS_OPTS` | Extra flags for `pg_regress` |

## Build Commands

```bash
# Build (in-tree)
cd src/postgresql-15.15/contrib/aqo
make

# Build (external PGXS)
USE_PGXS=1 make

# Install
make install

# Run regression tests
make check

# Clean
make clean
```

## Extension Control File (`aqo.control`)

```
# aqo extension
comment = 'Adaptive Query Optimization'
default_version = '1.6'
module_pathname = '$libdir/aqo'
relocatable = false
```

## SQL Migration Files

- `aqo--1.6.sql` — Full schema for fresh install at version 1.6
- `aqo--1.5--1.6.sql` — Migration from 1.5 to 1.6

Pattern: `CREATE EXTENSION aqo` uses the version in `.control` to find the right SQL file.

## Test Configuration (`aqo.conf`)

Loaded automatically during `make check` via `EXTRA_REGRESS_OPTS`:

```
shared_preload_libraries = 'aqo'
aqo.mode = 'disabled'
aqo.log_ignorance = 'off'
```

## Quick Recompile Workflow

```bash
# Quick rebuild (AQO only)
cd src/scripts && bash 03-recompile-extensions.sh --quick

# Full rebuild (PG + AQO + tests)
cd src/scripts && bash 03-recompile-extensions.sh
```
