#!/usr/bin/env bash
set -euo pipefail
# env/04-recompile.sh — Recompile PostgreSQL and/or the AQO extension after source changes.
# Source: was src/scripts/03-recompile-extensions.sh
#
# Usage:
#   bash env/04-recompile.sh              # Full recompile of PG + AQO
#   bash env/04-recompile.sh --aqo-only   # Only recompile AQO extension
#   bash env/04-recompile.sh --skip-tests # Skip AQO regression tests
#   bash env/04-recompile.sh --quick      # --aqo-only + --skip-tests

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$SCRIPTS_DIR/config.env"
# shellcheck source=../lib/common.sh
source "$SCRIPTS_DIR/lib/common.sh"

# ── Argument parsing ──────────────────────────────────────────────────────────
SKIP_POSTGRES=false
SKIP_TESTS=false

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --aqo-only    Only recompile AQO extension (skip PostgreSQL recompile)"
    echo "  --skip-tests  Skip running AQO regression tests"
    echo "  --quick       Same as --aqo-only --skip-tests"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0              # Full recompile of PostgreSQL and AQO"
    echo "  $0 --aqo-only   # Only recompile AQO extension"
    echo "  $0 --quick      # Quick rebuild of AQO only, no tests"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --aqo-only)   SKIP_POSTGRES=true; shift ;;
        --skip-tests) SKIP_TESTS=true;    shift ;;
        --quick)      SKIP_POSTGRES=true; SKIP_TESTS=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if [[ ! -d "$PG_SRC" ]]; then
    echo "[ERROR] PostgreSQL source folder not found: $PG_SRC" >&2
    echo "        Run env/01-build-postgres.sh first." >&2
    exit 1
fi

if [[ ! -e "$AQO_CONTRIB_LINK" ]]; then
    echo "[ERROR] AQO extension not found: $AQO_CONTRIB_LINK" >&2
    echo "        Run env/02-build-saqo.sh first to set up AQO." >&2
    exit 1
fi

# Check for broken symlink
if [[ -L "$AQO_CONTRIB_LINK" && ! -e "$AQO_CONTRIB_LINK" ]]; then
    echo "[ERROR] AQO symlink is broken: $AQO_CONTRIB_LINK" >&2
    echo "        Target: $(readlink "$AQO_CONTRIB_LINK")" >&2
    echo "        Run env/02-build-saqo.sh to fix." >&2
    exit 1
fi

echo ""
echo "==== Recompiling PostgreSQL and AQO Extension ===="

# Show AQO source location
if [[ -L "$AQO_CONTRIB_LINK" ]]; then
    echo "AQO source: $(readlink "$AQO_CONTRIB_LINK") (symlink)"
else
    echo "AQO source: $AQO_CONTRIB_LINK"
fi
echo ""

# Stop PostgreSQL before recompiling
pg_stop

# ── Recompile PostgreSQL ──────────────────────────────────────────────────────
if [[ "$SKIP_POSTGRES" == "false" ]]; then
    echo ""
    echo "Recompiling PostgreSQL..."
    cd "$PG_SRC"

    # Temporarily remove AQO symlink to avoid path issues during make clean.
    # The patch adds 'aqo' to contrib/Makefile SUBDIRS, so a stub is needed.
    AQO_SYMLINK_TARGET=""
    if [[ -L "$AQO_CONTRIB_LINK" ]]; then
        AQO_SYMLINK_TARGET=$(readlink "$AQO_CONTRIB_LINK")
        echo "        Temporarily removing AQO symlink during PG build..."
        rm -f "$AQO_CONTRIB_LINK"
    fi

    if [[ ! -d "$AQO_CONTRIB_LINK" ]]; then
        mkdir -p "$AQO_CONTRIB_LINK"
        cat > "$AQO_CONTRIB_LINK/Makefile" << 'EOF'
# Stub Makefile for make clean
all:
clean:
install:
.PHONY: all clean install
EOF
    fi

    make clean
    rm -rf "$AQO_CONTRIB_LINK"

    make -j"$(nproc)"
    sudo make install

    # Restore AQO symlink
    if [[ -n "$AQO_SYMLINK_TARGET" ]]; then
        echo "        Restoring AQO symlink..."
        ln -sfn "$AQO_SYMLINK_TARGET" "$AQO_CONTRIB_LINK"
    fi

    echo "[OK] PostgreSQL recompiled and installed"
else
    echo ""
    echo "[SKIP] PostgreSQL recompile (--aqo-only mode)"

    # Fix broken header symlinks (common after workspace directory moves)
    cd "$PG_SRC"
    fix_pg_src_symlinks

    # Ensure generated headers exist
    if [[ ! -f "$PG_SRC/src/backend/utils/errcodes.h" ]]; then
        echo "Generating required PostgreSQL headers..."
        make -C src/backend/utils errcodes.h
        make -C src/backend generated-headers
    fi
fi

# ── Recompile AQO extension ───────────────────────────────────────────────────
echo ""
echo "Recompiling AQO extension..."
cd "$SAQO_EXT"
make top_builddir="$PG_SRC" clean
make top_builddir="$PG_SRC"
sudo make top_builddir="$PG_SRC" install
echo "[OK] AQO extension recompiled and installed"

# Update aqo_semantic.so backup to reflect the freshly compiled binary
sudo cp "$PG_LIB/aqo.so" "$PG_LIB/aqo_semantic.so"
echo "[OK] Updated $PG_LIB/aqo_semantic.so backup"

# ── Run AQO regression tests ──────────────────────────────────────────────────
if [[ "$SKIP_TESTS" == "false" ]]; then
    echo ""
    echo "Running AQO regression tests..."
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
    umask 0077
    rm -rf "$SAQO_EXT/tmp_check" 2>/dev/null || true
    make top_builddir="$PG_SRC" -C "$SAQO_EXT" check 2>&1 \
        || echo "[WARN] Tests may have failed — check regression.diffs"
else
    echo ""
    echo "[SKIP] AQO regression tests (--skip-tests mode)"
fi

# ── Start PostgreSQL ──────────────────────────────────────────────────────────
echo ""
pg_start

# ── Verify AQO loaded ─────────────────────────────────────────────────────────
echo ""
echo "Verifying AQO extension..."
sudo -u postgres "$PG_BIN/psql" -d postgres -c \
    "SELECT extname, extversion FROM pg_extension WHERE extname = 'aqo';" 2>/dev/null \
    || echo "        Note: AQO extension not yet created in 'postgres' database"

echo ""
echo "==== Recompile Complete ===="

if [[ -L "$AQO_CONTRIB_LINK" ]]; then
    echo ""
    echo "To commit your changes:"
    echo "  cd $SAQO_REPO && git status"
fi
echo ""
