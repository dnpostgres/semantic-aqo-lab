#!/usr/bin/env bash
set -euo pipefail
# env/00-system-deps.sh — Install system-level dependencies for SAQO development.
# Source: was src/scripts/00-system-setup.sh

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$SCRIPTS_DIR/config.env"
# shellcheck source=../lib/common.sh
source "$SCRIPTS_DIR/lib/common.sh"

echo "==== Step 0: System Dependencies Setup ===="

# Update package index
sudo apt-get update

# Install build tools, PG build deps, and Python
sudo apt-get install -y \
    build-essential \
    git \
    wget \
    curl \
    libreadline-dev \
    zlib1g-dev \
    bison \
    flex \
    python3 \
    python3-pip \
    python3-venv

echo "[OK] System dependencies installed (build tools + Python 3 + venv)"
echo ""
echo "==== System Dependencies Done ===="
