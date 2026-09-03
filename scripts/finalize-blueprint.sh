#!/usr/bin/env bash
# This script intentionally does NOT fake Blueprint installation state.
# Use it only to run Blueprint's own installer after the pre-built assets
# are already present, when the server environment supports the installer.
set -Eeuo pipefail
cd "${PANEL_DIR:-$(pwd)}"

if [ ! -f blueprint.sh ]; then
  echo "ERROR: blueprint.sh not found."
  exit 1
fi

chmod +x blueprint.sh
bash blueprint.sh
