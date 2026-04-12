#!/usr/bin/env bash
set -euo pipefail
# env/03-build-std-aqo.sh — Clone postgrespro/aqo (stable15), build it, and save
# both binaries for use with switch-aqo.sh.
#
# After this script:
#   $PG_LIB/aqo_std.so      — standard AQO (postgrespro/aqo stable15)
#   $PG_LIB/aqo_semantic.so — semantic AQO backup
#
# Source: was src/scripts/04-standard-aqo-build.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$SCRIPTS_DIR/config.env"
# shellcheck source=../lib/common.sh
source "$SCRIPTS_DIR/lib/common.sh"

echo "============================================================"
echo "  Standard AQO (postgrespro/aqo stable15) Build"
echo "============================================================"
echo ""

# ── Step 1: Clone postgrespro/aqo ────────────────────────────────────────────
echo "Step 1: Clone postgrespro/aqo ($AQO_BRANCH)..."
if [[ -d "$STD_AQO_REPO" ]]; then
    echo "        Already cloned — pulling latest..."
    cd "$STD_AQO_REPO"
    git fetch origin
    git checkout "$AQO_BRANCH"
    git pull origin "$AQO_BRANCH"
else
    git clone -b "$AQO_BRANCH" --single-branch \
        "$STD_AQO_REPO_URL" "$STD_AQO_REPO"
fi
echo "[OK] Repo ready at $STD_AQO_REPO"

# ── Step 2: Verify PG source exists ──────────────────────────────────────────
echo ""
echo "Step 2: Checking PostgreSQL source tree..."
if [[ ! -d "$PG_SRC" ]]; then
    echo "[ERROR] $PG_SRC not found" >&2
    echo "        Run env/01-build-postgres.sh and env/02-build-saqo.sh first." >&2
    exit 1
fi
echo "[OK] Found $PG_SRC"

# ── Step 2.5: Fix any broken symlinks in PG source ───────────────────────────
echo ""
echo "Step 2.5: Fixing broken PG source symlinks..."
fix_pg_src_symlinks

# ── Step 3: Swap contrib/aqo symlink to standard AQO ─────────────────────────
echo ""
echo "Step 3: Pointing $AQO_CONTRIB_LINK -> standard AQO..."
rm -rf "$AQO_CONTRIB_LINK"
ln -sfn "$STD_AQO_REPO" "$AQO_CONTRIB_LINK"
echo "        contrib/aqo -> $STD_AQO_REPO"

# ── Step 4: Build standard AQO ───────────────────────────────────────────────
echo ""
echo "Step 4: Building standard AQO..."
cd "$STD_AQO_REPO"
make top_builddir="$PG_SRC" clean 2>/dev/null || true
# PG_CFLAGS suppresses GCC 14 incompatible-pointer-types error (compiler flag only,
# no source code changes).
make top_builddir="$PG_SRC" -j"$(nproc)" \
    PG_CFLAGS="-Wno-incompatible-pointer-types"
echo "[OK] Build successful"

# ── Step 5: Save binaries ─────────────────────────────────────────────────────
echo ""
echo "Step 5: Saving binaries..."
sudo cp "$STD_AQO_REPO/aqo.so" "$PG_LIB/aqo_std.so"
echo "        Saved: $PG_LIB/aqo_std.so"

if [[ -f "$PG_LIB/aqo.so" ]]; then
    sudo cp "$PG_LIB/aqo.so" "$PG_LIB/aqo_semantic.so"
    echo "        Saved: $PG_LIB/aqo_semantic.so"
fi

# Save SQL/control for each variant
sudo mkdir -p "$PG_SHARE/aqo_std_sql"
sudo cp "$STD_AQO_REPO"/*.sql     "$PG_SHARE/aqo_std_sql/" 2>/dev/null || true
sudo cp "$STD_AQO_REPO"/*.control "$PG_SHARE/aqo_std_sql/" 2>/dev/null || true

sudo mkdir -p "$PG_SHARE/aqo_semantic_sql"
sudo cp "$SAQO_EXT"/*.sql     "$PG_SHARE/aqo_semantic_sql/" 2>/dev/null || true
sudo cp "$SAQO_EXT"/*.control "$PG_SHARE/aqo_semantic_sql/" 2>/dev/null || true

echo "[OK] SQL/control files backed up"

# ── Step 6: Install standard AQO as active .so ───────────────────────────────
echo ""
echo "Step 6: Installing standard AQO as active aqo.so..."
pg_stop
sudo cp "$PG_LIB/aqo_std.so" "$PG_LIB/aqo.so"
sudo cp "$PG_SHARE/aqo_std_sql"/*.sql     "$PG_SHARE/" 2>/dev/null || true
sudo cp "$PG_SHARE/aqo_std_sql"/*.control "$PG_SHARE/" 2>/dev/null || true
pg_start
echo "[OK] Standard AQO installed and PostgreSQL restarted"

# ── Step 7: Restore contrib/aqo -> semantic AQO for future builds ────────────
echo ""
echo "Step 7: Restoring contrib/aqo -> $SAQO_EXT ..."
rm -f "$AQO_CONTRIB_LINK"
ln -sfn "$SAQO_EXT" "$AQO_CONTRIB_LINK"
echo "[OK] Restored: $AQO_CONTRIB_LINK -> $SAQO_EXT"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Standard AQO is now the active aqo.so"
echo ""
echo "  Switch at any time:"
echo "    bash $SCRIPTS_DIR/env/switch-aqo.sh standard"
echo "    bash $SCRIPTS_DIR/env/switch-aqo.sh semantic"
echo "============================================================"
