#!/usr/bin/env bash
# lib/common.sh — Shared helpers for all SAQO scripts.
#
# Usage: source "$SCRIPTS_DIR/lib/common.sh"
# Requires config.env to have been sourced first (PG_BIN, PG_DATA, PG_LOG, etc.).

# ---------------------------------------------------------------------------
# pg_stop — Stop PostgreSQL, wait, verify stopped
# ---------------------------------------------------------------------------
pg_stop() {
    echo "Stopping PostgreSQL..."
    sudo -u postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" stop 2>/dev/null || true

    local waited=0
    while sudo -u postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" status > /dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge 30 ]]; then
            echo "[ERROR] PostgreSQL did not stop within 30 seconds" >&2
            exit 1
        fi
    done
    echo "[OK] PostgreSQL stopped"
}

# ---------------------------------------------------------------------------
# pg_start — Start PostgreSQL, wait, verify started
# ---------------------------------------------------------------------------
pg_start() {
    echo "Starting PostgreSQL..."
    sudo -u postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" -l "$PG_LOG" start

    local waited=0
    while ! sudo -u postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" status > /dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge 30 ]]; then
            echo "[ERROR] PostgreSQL did not start within 30 seconds — check $PG_LOG" >&2
            exit 1
        fi
    done

    # Extra wait for postmaster to be ready for connections
    local conn_waited=0
    until sudo -u postgres "$PG_BIN/psql" -d postgres -c "SELECT 1;" > /dev/null 2>&1; do
        sleep 1
        conn_waited=$((conn_waited + 1))
        if [[ $conn_waited -ge 20 ]]; then
            echo "[ERROR] PostgreSQL started but not accepting connections — check $PG_LOG" >&2
            exit 1
        fi
    done
    echo "[OK] PostgreSQL started and accepting connections"
}

# ---------------------------------------------------------------------------
# pg_restart — Stop then start PostgreSQL
# ---------------------------------------------------------------------------
pg_restart() {
    pg_stop
    pg_start
}

# ---------------------------------------------------------------------------
# pg_ensure_running — Start if not running, no-op if already running
# ---------------------------------------------------------------------------
pg_ensure_running() {
    if sudo -u postgres "$PG_BIN/pg_ctl" -D "$PG_DATA" status > /dev/null 2>&1; then
        echo "[SKIP] PostgreSQL is already running"
    else
        pg_start
    fi
}

# ---------------------------------------------------------------------------
# db_exists DB — Returns 0 if database DB exists, 1 otherwise
# ---------------------------------------------------------------------------
db_exists() {
    local db="$1"
    local count
    count=$(sudo -u postgres "$PG_BIN/psql" -d postgres -tAc \
        "SELECT COUNT(*) FROM pg_database WHERE datname = '$db';" 2>/dev/null || echo "0")
    [[ "$count" -ge 1 ]]
}

# ---------------------------------------------------------------------------
# ensure_aqo_in_db DB — CREATE EXTENSION IF NOT EXISTS aqo in the given DB
# ---------------------------------------------------------------------------
ensure_aqo_in_db() {
    local db="$1"
    echo "Ensuring AQO extension in database: $db"
    sudo -u postgres "$PG_BIN/psql" -d "$db" -c "CREATE EXTENSION IF NOT EXISTS aqo;" 2>/dev/null
    echo "[OK] AQO extension present in $db"
}

# ---------------------------------------------------------------------------
# load_token_embeddings DB — Run load-token-embeddings.py for a specific DB
# ---------------------------------------------------------------------------
load_token_embeddings() {
    local db="${1:-postgres}"
    echo "Loading token embeddings into database: $db"
    python3 "$SCRIPTS_DIR/load-token-embeddings.py" --db "$db"
    echo "[OK] Token embeddings loaded into $db"
}

# ---------------------------------------------------------------------------
# fix_pg_src_symlinks — Fix broken header symlinks in PG source tree
#   (needed when the workspace directory has moved)
# ---------------------------------------------------------------------------
fix_pg_src_symlinks() {
    echo "Checking and fixing broken PG source header symlinks..."
    local fixed=0

    while IFS= read -r -d '' lnk; do
        if [[ ! -e "$lnk" ]]; then
            local target rel
            target=$(readlink "$lnk")
            # Extract the relative portion after postgresql-<ver>/
            rel=$(echo "$target" | sed 's|.*/postgresql-[0-9.]*\/\(.*\)|\1|')
            if [[ -f "$PG_SRC/$rel" ]]; then
                rm -f "$lnk"
                ln -s "$PG_SRC/$rel" "$lnk"
                fixed=$((fixed + 1))
            fi
        fi
    done < <(find "$PG_SRC/src/include" -type l -print0 2>/dev/null)

    if [[ $fixed -gt 0 ]]; then
        echo "[OK] Fixed $fixed broken symlinks"
    else
        echo "[OK] All symlinks are valid"
    fi
}

# ---------------------------------------------------------------------------
# verify_aqo_variant EXPECTED_VARIANT
#
# CRITICAL safety check: verifies that the active aqo.so matches the expected
# variant by comparing md5sums against the known-good backup binaries.
#
# Arguments:
#   EXPECTED_VARIANT — "standard" or "semantic"
#
# Returns 0 on match. Exits 1 (FAIL-STOP) on mismatch or if aqo.so is missing.
# ---------------------------------------------------------------------------
verify_aqo_variant() {
    local expected="$1"

    if [[ "$expected" != "standard" && "$expected" != "semantic" ]]; then
        echo "[ERROR] verify_aqo_variant: invalid argument '$expected' — use 'standard' or 'semantic'" >&2
        exit 1
    fi

    # --- md5sum comparison ---
    if [[ ! -f "$PG_LIB/aqo.so" ]]; then
        echo "[ERROR] VARIANT VERIFICATION FAILED: $PG_LIB/aqo.so is missing" >&2
        exit 1
    fi

    local md5_active md5_expected_file expected_so
    if [[ "$expected" == "standard" ]]; then
        expected_so="$PG_LIB/aqo_std.so"
    else
        expected_so="$PG_LIB/aqo_semantic.so"
    fi

    if [[ ! -f "$expected_so" ]]; then
        echo "[ERROR] VARIANT VERIFICATION FAILED: reference binary $expected_so not found" >&2
        echo "        Run env/03-build-std-aqo.sh first to create both backup binaries." >&2
        exit 1
    fi

    md5_active=$(md5sum "$PG_LIB/aqo.so" | awk '{print $1}')
    md5_expected_file=$(md5sum "$expected_so" | awk '{print $1}')

    if [[ "$md5_active" != "$md5_expected_file" ]]; then
        echo "" >&2
        echo "=========================================================" >&2
        echo "[ERROR] AQO VARIANT MISMATCH — FAIL STOP" >&2
        echo "  Expected variant : $expected" >&2
        echo "  Reference binary : $expected_so" >&2
        echo "  Active aqo.so    : $PG_LIB/aqo.so" >&2
        echo "  md5(active)      : $md5_active" >&2
        echo "  md5(expected)    : $md5_expected_file" >&2
        echo "" >&2
        echo "  The switch DID NOT complete correctly." >&2
        echo "  Experiments run now would use the WRONG AQO core and" >&2
        echo "  produce garbage data. Halting." >&2
        echo "=========================================================" >&2
        exit 1
    fi

    # --- aqo_version() query (secondary confirmation) ---
    local version_output
    version_output=$(sudo -u postgres "$PG_BIN/psql" -d postgres -tAc \
        "SELECT aqo_version();" 2>/dev/null || echo "")

    if [[ "$expected" == "semantic" ]]; then
        if [[ -z "$version_output" ]]; then
            echo "[ERROR] VARIANT VERIFICATION FAILED: semantic AQO should export aqo_version() but returned nothing" >&2
            exit 1
        fi
        echo "[OK] Variant verified: semantic (aqo_version = $version_output)"
    else
        # Standard postgrespro/aqo stable15 does not export aqo_version()
        echo "[OK] Variant verified: standard (md5sum matches aqo_std.so)"
        if [[ -n "$version_output" ]]; then
            echo "     Note: aqo_version() returned '$version_output' (unexpected for standard AQO)"
        fi
    fi
}
