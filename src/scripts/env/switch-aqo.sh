#!/usr/bin/env bash
set -euo pipefail
# env/switch-aqo.sh — Hot-swap the active AQO variant between standard and semantic.
#
# CRITICAL: After every switch, the active aqo.so is verified against the known-good
# backup binary via md5sum. If verification fails, the script exits 1 (FAIL-STOP).
# A silent switch failure would cause experiments to run against the wrong AQO core
# and produce garbage benchmark data.
#
# Prerequisites: Run env/03-build-std-aqo.sh first to populate:
#   $PG_LIB/aqo_std.so
#   $PG_LIB/aqo_semantic.so
#
# Usage:
#   bash env/switch-aqo.sh standard    # activate postgrespro/aqo
#   bash env/switch-aqo.sh semantic    # activate semantic-aqo
#   bash env/switch-aqo.sh status      # show which variant is currently active

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$SCRIPTS_DIR/config.env"
# shellcheck source=../lib/common.sh
source "$SCRIPTS_DIR/lib/common.sh"

# ── active_variant — report which .so is currently active ────────────────────
active_variant() {
    if [[ ! -f "$PG_LIB/aqo.so" ]]; then
        echo "unknown (aqo.so missing)"
        return
    fi
    local md5_active md5_std md5_sem
    md5_active=$(md5sum "$PG_LIB/aqo.so" | awk '{print $1}')
    md5_std=$(md5sum "$PG_LIB/aqo_std.so"     2>/dev/null | awk '{print $1}' || echo "x")
    md5_sem=$(md5sum "$PG_LIB/aqo_semantic.so" 2>/dev/null | awk '{print $1}' || echo "y")

    if [[ "$md5_active" == "$md5_std" ]]; then
        echo "standard (postgrespro/aqo stable15)"
    elif [[ "$md5_active" == "$md5_sem" ]]; then
        echo "semantic (semantic-aqo)"
    else
        echo "unknown (modified or untracked .so)"
    fi
}

# ── Argument handling ─────────────────────────────────────────────────────────
VARIANT="${1:-}"
if [[ -z "$VARIANT" ]]; then
    echo "Usage: $0 {standard|semantic|status}" >&2
    exit 1
fi

if [[ "$VARIANT" == "status" ]]; then
    echo "Active AQO variant: $(active_variant)"
    exit 0
fi

if [[ "$VARIANT" != "standard" && "$VARIANT" != "semantic" ]]; then
    echo "[ERROR] Unknown variant '$VARIANT'. Use 'standard' or 'semantic'." >&2
    exit 1
fi

# ── Pre-flight: variant binaries must exist ───────────────────────────────────
if [[ "$VARIANT" == "standard" ]]; then
    SO_SRC="$PG_LIB/aqo_std.so"
    SQL_DIR="$PG_SHARE/aqo_std_sql"
else
    SO_SRC="$PG_LIB/aqo_semantic.so"
    SQL_DIR="$PG_SHARE/aqo_semantic_sql"
fi

if [[ ! -f "$SO_SRC" ]]; then
    echo "[ERROR] $SO_SRC not found." >&2
    echo "        Run: bash $SCRIPTS_DIR/env/03-build-std-aqo.sh" >&2
    exit 1
fi

echo "============================================================"
echo "  Switching AQO -> $VARIANT"
echo "  Source: $SO_SRC"
echo "============================================================"

# ── Step 1: Stop PostgreSQL ───────────────────────────────────────────────────
echo ""
pg_stop

# ── Step 2: Swap .so ──────────────────────────────────────────────────────────
echo ""
echo "Installing $VARIANT AQO binary..."
sudo cp "$SO_SRC" "$PG_LIB/aqo.so"
echo "[OK] aqo.so replaced"

# ── Step 3: Swap SQL/control files ───────────────────────────────────────────
if [[ -d "$SQL_DIR" ]] && ls "$SQL_DIR"/*.sql "$SQL_DIR"/*.control > /dev/null 2>&1; then
    echo ""
    echo "Updating SQL/control files from $SQL_DIR ..."
    sudo cp "$SQL_DIR"/*.sql     "$PG_SHARE/" 2>/dev/null || true
    sudo cp "$SQL_DIR"/*.control "$PG_SHARE/" 2>/dev/null || true
    echo "[OK] SQL/control files updated"
else
    echo "[WARN] No SQL dir at $SQL_DIR — control files unchanged"
fi

# ── Step 4: Start PostgreSQL ──────────────────────────────────────────────────
echo ""
pg_start

# ── Step 5: CRITICAL — verify variant is correct (FAIL-STOP) ─────────────────
echo ""
echo "Verifying AQO variant after switch (FAIL-STOP if mismatch)..."
verify_aqo_variant "$VARIANT"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  AQO switched to: $VARIANT"
echo "  Active variant  : $(active_variant)"
echo "============================================================"
