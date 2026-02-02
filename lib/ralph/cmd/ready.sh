#!/usr/bin/env bash
set -euo pipefail

# ralph ready (DEPRECATED)
# This command has been renamed to 'ralph todo'.
# This wrapper provides backward compatibility with a deprecation warning.

echo "WARNING: 'ralph ready' is deprecated. Use 'ralph todo' instead." >&2

# Forward to the new command
exec "$(dirname "$0")/todo.sh" "$@"
