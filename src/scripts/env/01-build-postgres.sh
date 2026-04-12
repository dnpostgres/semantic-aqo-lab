#!/usr/bin/env bash
set -euo pipefail
# env/01-build-postgres.sh — Download, build, and install PostgreSQL from source.
# Source: was src/scripts/01-postgres-clone-and-build.sh
#
# Flow:
#   download tarball -> extract -> configure -> make -> install
#   -> create postgres user -> init cluster -> start server -> verify

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$SCRIPTS_DIR/config.env"
# shellcheck source=../lib/common.sh
source "$SCRIPTS_DIR/lib/common.sh"

echo "==== PostgreSQL $PG_VERSION Download, Build, and Installation ===="
echo ""

SRC_PARENT="$REPO_ROOT/src"
TARBALL="postgresql-${PG_VERSION}.tar.gz"

# Step 1: Download PostgreSQL source
echo "Step 1: Downloading PostgreSQL $PG_VERSION..."
cd "$SRC_PARENT"

if [[ ! -f "$TARBALL" ]]; then
    wget "https://ftp.postgresql.org/pub/source/v${PG_VERSION}/${TARBALL}"
    echo "[OK] Tarball downloaded"
else
    echo "[SKIP] Tarball already exists"
fi

# Step 2: Extract source
echo ""
echo "Step 2: Extracting source code..."
if [[ -d "$PG_SRC" ]]; then
    echo "[SKIP] Source directory already exists: $PG_SRC"
else
    tar xf "$TARBALL"
    echo "[OK] Extracted to $PG_SRC"
fi

# Clean up tarball after successful extraction
if [[ -d "$PG_SRC" && -f "$SRC_PARENT/$TARBALL" ]]; then
    rm -f "$SRC_PARENT/$TARBALL"
    echo "[OK] Tarball removed"
fi

cd "$PG_SRC"

# Step 3: Configure
echo ""
echo "Step 3: Configuring PostgreSQL (prefix=$PG_PREFIX)..."
./configure --prefix="$PG_PREFIX"

# Step 4: Build
echo ""
echo "Step 4: Building PostgreSQL ($(nproc) cores)..."
make -j"$(nproc)"

# Step 5: Install
echo ""
echo "Step 5: Installing PostgreSQL to $PG_PREFIX..."
sudo make install
echo "[OK] PostgreSQL installed to $PG_PREFIX"

# Step 6: Create postgres OS user
echo ""
echo "Step 6: Creating postgres OS user..."
if id "postgres" &>/dev/null; then
    echo "[SKIP] User postgres already exists"
else
    sudo adduser --system --no-create-home --group postgres \
        || sudo useradd -r -s /bin/bash postgres
    echo "[OK] User postgres created"
fi

# Step 7: Create data directory and set permissions
echo ""
echo "Step 7: Setting up data directory: $PG_DATA"
sudo mkdir -p "$PG_DATA"
sudo chown postgres:postgres "$PG_DATA"
sudo chmod 700 "$PG_DATA"
echo "[OK] Data directory ready: $PG_DATA"

# Step 8: Initialize cluster
echo ""
echo "Step 8: Initializing database cluster..."
sudo -u postgres "$PG_BIN/initdb" -D "$PG_DATA"
echo "[OK] Database cluster initialized"

# Step 9: Start PostgreSQL
echo ""
pg_start

# Step 10: Create a basic test database
echo ""
echo "Step 10: Creating test database..."
if db_exists "test"; then
    echo "[SKIP] Database 'test' already exists"
else
    sudo -u postgres "$PG_BIN/createdb" test
    echo "[OK] Test database created"
fi

# Step 11: Verify installation
echo ""
echo "Step 11: Verifying installation..."
sudo -u postgres "$PG_BIN/psql" test -c "SELECT version();"

# Step 12: Add PG binaries to PATH in ~/.bashrc
echo ""
echo "Step 12: Adding $PG_BIN to PATH..."
EXPORT_LINE="export PATH=$PG_BIN:\$PATH"
if grep -Fxq "$EXPORT_LINE" ~/.bashrc 2>/dev/null; then
    echo "[SKIP] PATH already configured in ~/.bashrc"
else
    echo "$EXPORT_LINE" >> ~/.bashrc
    echo "[OK] PATH added to ~/.bashrc"
fi

echo ""
echo "==== PostgreSQL $PG_VERSION Installation Complete ===="
echo ""
echo "Usage:"
echo "  Connect : $PG_BIN/psql -U postgres test"
echo "  Start   : sudo -u postgres $PG_BIN/pg_ctl -D $PG_DATA start"
echo "  Stop    : sudo -u postgres $PG_BIN/pg_ctl -D $PG_DATA stop"
echo "  Status  : sudo -u postgres $PG_BIN/pg_ctl -D $PG_DATA status"
