#!/usr/bin/env bash
set -euo pipefail

# ralph use <name>
# Switches the active workflow by setting state/current after validation:
# 1. Validates the spec exists (specs/<name>.md or hidden spec in state/<name>.md)
# 2. Validates state/<name>.json exists (workflow must be initialized via ralph plan)
# 3. Writes the label to state/current (plain text, no extension)
# 4. Errors with clear message if either validation fails

# Load shared helpers
# shellcheck source=util.sh
source "$(dirname "$0")/util.sh"

RALPH_DIR="${RALPH_DIR:-.wrapix/ralph}"
SPECS_DIR="specs"

# Parse arguments
if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo "Error: Label is required"
  echo ""
  echo "Usage: ralph use <name>"
  echo ""
  echo "Switches the active workflow to <name>."
  echo "The workflow must have been initialized via 'ralph plan'."
  exit 1
fi

LABEL="$1"

# (1) Validate the spec exists: specs/<name>.md or hidden spec in state/<name>.md
SPEC_FILE="$SPECS_DIR/$LABEL.md"
HIDDEN_SPEC_FILE="$RALPH_DIR/state/$LABEL.md"

if [ ! -f "$SPEC_FILE" ] && [ ! -f "$HIDDEN_SPEC_FILE" ]; then
  echo "Error: Spec not found for '$LABEL'"
  echo "  Checked: $SPEC_FILE"
  echo "  Checked: $HIDDEN_SPEC_FILE"
  echo ""
  echo "Create a spec first with: ralph plan -n $LABEL"
  exit 1
fi

# (2) Validate state/<name>.json exists (workflow must be initialized via ralph plan)
STATE_FILE="$RALPH_DIR/state/$LABEL.json"

if [ ! -f "$STATE_FILE" ]; then
  echo "Error: Workflow state not found for '$LABEL'"
  echo "  Expected: $STATE_FILE"
  echo ""
  echo "Initialize the workflow first with: ralph plan -n $LABEL"
  exit 1
fi

# (3) Write the label to state/current (plain text, no extension)
CURRENT_POINTER="$RALPH_DIR/state/current"
mkdir -p "$(dirname "$CURRENT_POINTER")"
echo "$LABEL" > "$CURRENT_POINTER"

debug "Switched active workflow to: $LABEL"
echo "Active workflow: $LABEL"
