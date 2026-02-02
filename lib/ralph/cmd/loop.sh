#!/usr/bin/env bash
set -euo pipefail

# DEPRECATED: Use 'ralph run' instead
# This command forwards to ralph-run

echo "Warning: 'ralph loop' is deprecated. Use 'ralph run' instead." >&2

exec ralph-run "$@"
