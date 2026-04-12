#!/usr/bin/env bash
set -euo pipefail
# env/02-build-saqo.sh — Clone semantic-aqo-main, build PG with patch, build AQO extension.
# Source: was src/scripts/02-semantic-aqo-clone-and-build.sh
#
# Flow:
#   clone repo -> apply PG patch -> build PG -> symlink contrib/aqo
#   -> build AQO -> configure shared_preload_libraries -> start -> create extension
#   -> load token embeddings

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$SCRIPTS_DIR/config.env"
# shellcheck source=../lib/common.sh
source "$SCRIPTS_DIR/lib/common.sh"

POSTGRES_MAJOR_VERSION=15  # major version used for patch filename

echo "==== Semantic AQO Extension Build ===="
echo ""

# Guard: PG source must already exist (run 01-build-postgres.sh first)
if [[ ! -d "$PG_SRC" ]]; then
    echo "[ERROR] PostgreSQL source folder not found: $PG_SRC" >&2
    echo "        Run env/01-build-postgres.sh first." >&2
    exit 1
fi

# ── Step 1: Clone semantic-aqo-main ───────────────────────────────────────────
echo "Step 1: Clone semantic-aqo-main repository..."
if [[ ! -d "$SAQO_REPO" ]]; then
    git clone -b "$AQO_BRANCH" --single-branch "$SAQO_REPO_URL" "$SAQO_REPO"
    echo "[OK] Repository cloned to $SAQO_REPO"
else
    echo "[SKIP] Repository already exists at $SAQO_REPO"
fi

if [[ ! -d "$SAQO_EXT" ]]; then
    echo "[ERROR] Extension folder not found: $SAQO_EXT" >&2
    echo "        The repository structure may have changed. Expected: extension/ subfolder." >&2
    exit 1
fi

# ── Step 2: Apply AQO patch to PostgreSQL source ──────────────────────────────
echo ""
echo "Step 2: Applying AQO patch to PostgreSQL source..."
cd "$PG_SRC"

PATCH_FILE="$SAQO_EXT/aqo_pg${POSTGRES_MAJOR_VERSION}.patch"
if [[ ! -f "$PATCH_FILE" ]]; then
    echo "[ERROR] Patch file not found: $PATCH_FILE" >&2
    exit 1
fi

if ! patch -p1 --no-backup-if-mismatch --dry-run < "$PATCH_FILE" > /dev/null 2>&1; then
    echo "[SKIP] Patch already applied or not needed"
else
    patch -p1 --no-backup-if-mismatch < "$PATCH_FILE"
    echo "[OK] Patch applied"
fi

# ── Step 3: Build and install PostgreSQL ──────────────────────────────────────
echo ""
echo "Step 3: Building and installing PostgreSQL (with AQO patch)..."
echo "        (This will take a few minutes)"

# Remove symlink BEFORE make clean to avoid path issues.
# The patch adds 'aqo' to contrib/Makefile SUBDIRS, so a stub is needed.
if [[ -L "$AQO_CONTRIB_LINK" ]]; then
    echo "        Removing existing symlink before build..."
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
echo "[OK] PostgreSQL built and installed"

# ── Step 4: Create contrib/aqo symlink ────────────────────────────────────────
echo ""
echo "Step 4: Creating contrib/aqo -> $SAQO_EXT ..."
if [[ -L "$AQO_CONTRIB_LINK" ]]; then
    rm -f "$AQO_CONTRIB_LINK"
elif [[ -d "$AQO_CONTRIB_LINK" ]]; then
    rm -rf "$AQO_CONTRIB_LINK"
fi
ln -sfn "$SAQO_EXT" "$AQO_CONTRIB_LINK"
echo "[OK] Symlink created: $AQO_CONTRIB_LINK -> $SAQO_EXT"

# ── Step 5: Build AQO extension ───────────────────────────────────────────────
echo ""
echo "Step 5: Building AQO extension..."
cd "$SAQO_EXT"

make top_builddir="$PG_SRC" clean 2>/dev/null || true
make top_builddir="$PG_SRC"
sudo make top_builddir="$PG_SRC" install
echo "[OK] AQO extension built and installed"

# ── Step 6: Save semantic AQO .so backup ──────────────────────────────────────
echo ""
echo "Step 6: Saving aqo_semantic.so backup..."
sudo cp "$PG_LIB/aqo.so" "$PG_LIB/aqo_semantic.so"
echo "[OK] Backup saved: $PG_LIB/aqo_semantic.so"

# Save SQL/control files for switch-aqo.sh
sudo mkdir -p "$PG_SHARE/aqo_semantic_sql"
sudo cp "$SAQO_EXT"/*.sql     "$PG_SHARE/aqo_semantic_sql/" 2>/dev/null || true
sudo cp "$SAQO_EXT"/*.control "$PG_SHARE/aqo_semantic_sql/" 2>/dev/null || true
echo "[OK] SQL/control files backed up to $PG_SHARE/aqo_semantic_sql/"

# ── Step 7: Configure shared_preload_libraries ────────────────────────────────
echo ""
echo "Step 7: Configuring PostgreSQL to load AQO on startup..."

pg_stop

CONF_FILE="$PG_DATA/postgresql.conf"
if grep -q "^shared_preload_libraries.*aqo" "$CONF_FILE" 2>/dev/null; then
    echo "[SKIP] AQO already in shared_preload_libraries"
else
    sudo cp "$CONF_FILE" "${CONF_FILE}.backup"
    if grep -q "^shared_preload_libraries" "$CONF_FILE"; then
        sudo sed -i "s/^shared_preload_libraries = '\(.*\)'/shared_preload_libraries = '\1,aqo'/" "$CONF_FILE"
        # Clean up accidental leading comma: '',aqo -> 'aqo'
        sudo sed -i "s/shared_preload_libraries = '',/shared_preload_libraries = '/" "$CONF_FILE"
    else
        printf "\nshared_preload_libraries = 'aqo'\n" | sudo tee -a "$CONF_FILE" > /dev/null
    fi
    echo "[OK] Added AQO to shared_preload_libraries"
fi

# ── Step 8: Start PostgreSQL and create extension ─────────────────────────────
echo ""
echo "Step 8: Starting PostgreSQL server..."
pg_start

echo ""
echo "Creating AQO extension in default database (postgres)..."

# Drop any conflicting standalone tables before creating extension
sudo -u postgres "$PG_BIN/psql" -d postgres -c "
    DROP TABLE IF EXISTS token_embeddings CASCADE;
    DROP TABLE IF EXISTS aqo_queries CASCADE;
    DROP TABLE IF EXISTS aqo_query_texts CASCADE;
    DROP TABLE IF EXISTS aqo_query_stat CASCADE;
    DROP TABLE IF EXISTS aqo_data CASCADE;
    DROP TABLE IF EXISTS aqo_node_context CASCADE;
" 2>/dev/null || true

ensure_aqo_in_db "postgres"

# ── Step 8.5: Load token embeddings ───────────────────────────────────────────
echo ""
echo "Step 8.5: Loading token embeddings into postgres database..."
python3 "$SCRIPTS_DIR/load-token-embeddings.py"
echo "[OK] Token embeddings loaded"

# ── Step 9: Verify installation ───────────────────────────────────────────────
echo ""
echo "Step 9: Verifying AQO extension..."
sudo -u postgres "$PG_BIN/psql" -d postgres -c \
    "SELECT extname, extversion FROM pg_extension WHERE extname = 'aqo';"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "==== Semantic AQO Extension Build Complete ===="
echo ""
echo "AQO is configured and ready. Configuration:"
echo "  shared_preload_libraries = 'aqo'  in $PG_DATA/postgresql.conf"
echo ""
echo "To use AQO in other databases:"
echo "  sudo -u postgres $PG_BIN/psql -d <db> -c \"CREATE EXTENSION aqo;\""
echo ""
echo "Development workflow:"
echo "  AQO repo    : $SAQO_REPO"
echo "  Extension   : $SAQO_EXT"
echo "  Symlink     : $AQO_CONTRIB_LINK -> $SAQO_EXT"
echo ""
echo "  Edit source files in: $SAQO_EXT/"
echo "  Recompile   : bash $SCRIPTS_DIR/env/04-recompile.sh --quick"
