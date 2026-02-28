#!/usr/bin/env bash
# Convenience wrapper — runs the sandbox step from update.sh
# For full options, use: bash update.sh --sandbox
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/update.sh" --sandbox
