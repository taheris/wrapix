#!/usr/bin/env bash
set -euo pipefail

# ralph todo [--spec <name>|-s <name>]
# Converts spec to beads with task breakdown
# - Accepts --spec/-s flag to target a specific workflow
# - Pins context by reading specs/README.md
# - Reads spec from per-label state file (state/<label>.json)
# - Analyzes spec and creates task breakdown
# - Creates parent/epic bead, then child tasks
# - Updates specs/README.md WIP table with parent bead ID
# - Finalizes spec to specs/ (stripping Implementation Notes section)

# Parse --spec/-s flag early (before container detection, so it's included in RALPH_ARGS)
SPEC_FLAG=""
TODO_ARGS=()

for arg in "$@"; do
  if [ "${_next_is_spec:-}" = "1" ]; then
    SPEC_FLAG="$arg"
    unset _next_is_spec
    continue
  fi
  case "$arg" in
    --spec|-s)
      _next_is_spec=1
      ;;
    --spec=*)
      SPEC_FLAG="${arg#--spec=}"
      ;;
    *)
      TODO_ARGS+=("$arg")
      ;;
  esac
done
unset _next_is_spec

# Replace positional params with filtered args
set -- "${TODO_ARGS[@]+"${TODO_ARGS[@]}"}"

# Container detection: if not in container and wrapix is available, re-launch in container
# /etc/wrapix/claude-config.json only exists inside containers (baked into image)
if [ ! -f /etc/wrapix/claude-config.json ] && command -v wrapix &>/dev/null; then
  export RALPH_MODE=1
  export RALPH_CMD=todo
  # Preserve --spec flag in args for container re-exec
  if [ -n "$SPEC_FLAG" ]; then
    export RALPH_ARGS="--spec $SPEC_FLAG ${*:-}"
  else
    export RALPH_ARGS="${*:-}"
  fi
  exec wrapix
fi

# Load shared helpers
# shellcheck source=util.sh
source "$(dirname "$0")/util.sh"

RALPH_DIR="${RALPH_DIR:-.wrapix/ralph}"

CONFIG_FILE="$RALPH_DIR/config.nix"
SPECS_DIR="specs"
SPECS_README="$SPECS_DIR/README.md"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: No ralph config found at $CONFIG_FILE"
  echo "Run 'ralph plan <label>' first."
  exit 1
fi

# Resolve the spec label using --spec flag or state/current
LABEL=$(resolve_spec_label "$SPEC_FLAG")

# Read state from per-label state file: state/<label>.json
STATE_FILE="$RALPH_DIR/state/${LABEL}.json"
SPEC_HIDDEN=$(jq -r '.hidden // false' "$STATE_FILE")
UPDATE_MODE=$(jq -r '.update // false' "$STATE_FILE")

# Load config for stream filter
CONFIG=$(nix eval --json --file "$CONFIG_FILE")

# Compute spec path and README instructions based on hidden flag
if [ "$SPEC_HIDDEN" = "true" ]; then
  SPEC_PATH="$RALPH_DIR/state/$LABEL.md"
  README_INSTRUCTIONS=""
else
  SPEC_PATH="$SPECS_DIR/$LABEL.md"
  README_INSTRUCTIONS="## README Update

After creating the molecule, update \`specs/README.md\`:
- Find the row for this spec
- Update the Beads column with the molecule ID (epic ID)"
fi

# Check spec file exists
if [ ! -f "$SPEC_PATH" ]; then
  echo "Error: Spec file not found: $SPEC_PATH"
  echo "Run 'ralph plan' first to create the specification."
  exit 1
fi

# Path for new requirements in update mode (written by ralph plan -u)
NEW_REQUIREMENTS_PATH="$RALPH_DIR/state/$LABEL.md"
NEW_REQUIREMENTS=""

# In update mode, check for state/<label>.md with new requirements
if [ "$UPDATE_MODE" = "true" ]; then
  if [ ! -f "$NEW_REQUIREMENTS_PATH" ]; then
    echo "No new requirements found at $NEW_REQUIREMENTS_PATH"
    echo ""
    echo "To add new requirements to this spec, run:"
    echo "  ralph plan -u $LABEL"
    echo ""
    echo "This will gather new requirements and write them to $NEW_REQUIREMENTS_PATH,"
    echo "which ralph todo will then process."
    exit 0
  fi
  NEW_REQUIREMENTS=$(cat "$NEW_REQUIREMENTS_PATH")
fi

# Select template based on mode: todo-new for new specs, todo-update for updates
if [ "$UPDATE_MODE" = "true" ]; then
  TEMPLATE_NAME="todo-update"
else
  TEMPLATE_NAME="todo-new"
fi

mkdir -p "$RALPH_DIR/logs"

# Pin context from specs/README.md
PINNED_CONTEXT=""
if [ -f "$SPECS_README" ]; then
  PINNED_CONTEXT=$(cat "$SPECS_README")
fi

# Extract title from spec file (first heading)
SPEC_TITLE=$(grep -m 1 '^#' "$SPEC_PATH" | sed 's/^#* *//' || echo "$LABEL")

# Get molecule ID from per-label state file (for update mode)
MOLECULE_ID=$(jq -r '.molecule // empty' "$STATE_FILE")

# Count existing tasks (for status display in update mode)
EXISTING_COUNT=0
if [ "$UPDATE_MODE" = "true" ]; then
  EXISTING_BEADS=$(bd list -l "spec-$LABEL" --json 2>/dev/null || echo "[]")
  EXISTING_COUNT=$(echo "$EXISTING_BEADS" | jq 'length')
fi

echo "Ralph Todo: Converting spec to molecule..."
echo "  Label: $LABEL"
echo "  Spec: $SPEC_PATH"
echo "  Title: $SPEC_TITLE"
if [ "$UPDATE_MODE" = "true" ]; then
  if [ -n "$MOLECULE_ID" ]; then
    echo "  Mode: UPDATE (bonding new tasks to existing molecule)"
    echo "  Molecule: $MOLECULE_ID"
  else
    echo "  Mode: UPDATE (creating molecule for existing spec)"
    echo "  Creating epic..."
    MOLECULE_ID=$(bd create --type=epic --title="$SPEC_TITLE" --labels="spec-$LABEL" --silent)
    jq --arg mol "$MOLECULE_ID" '.molecule = $mol' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    echo "  Molecule: $MOLECULE_ID"
  fi
  echo "  Existing tasks: $EXISTING_COUNT"
else
  echo "  Mode: NEW (creating molecule from scratch)"
fi
echo ""

# Read spec content for template
SPEC_CONTENT=""
if [ -f "$SPEC_PATH" ]; then
  SPEC_CONTENT=$(cat "$SPEC_PATH")
fi

# Render template using centralized render_template function
# Variables differ based on template type
if [ "$UPDATE_MODE" = "true" ]; then
  # Compute molecule progress (for ready-update template)
  MOLECULE_PROGRESS=""
  if [ -n "$MOLECULE_ID" ]; then
    # Try to get progress from bd mol progress
    PROGRESS_OUTPUT=$(bd mol progress "$MOLECULE_ID" 2>/dev/null || true)
    if [ -n "$PROGRESS_OUTPUT" ]; then
      MOLECULE_PROGRESS="$PROGRESS_OUTPUT"
    fi
  fi

  PROMPT_CONTENT=$(render_template "$TEMPLATE_NAME" \
    "LABEL=$LABEL" \
    "SPEC_PATH=$SPEC_PATH" \
    "EXISTING_SPEC=$SPEC_CONTENT" \
    "MOLECULE_ID=$MOLECULE_ID" \
    "MOLECULE_PROGRESS=$MOLECULE_PROGRESS" \
    "NEW_REQUIREMENTS=$NEW_REQUIREMENTS" \
    "NEW_REQUIREMENTS_PATH=$NEW_REQUIREMENTS_PATH" \
    "PINNED_CONTEXT=$PINNED_CONTEXT" \
    "README_INSTRUCTIONS=$README_INSTRUCTIONS" \
    "EXIT_SIGNALS=")
else
  PROMPT_CONTENT=$(render_template "$TEMPLATE_NAME" \
    "LABEL=$LABEL" \
    "SPEC_PATH=$SPEC_PATH" \
    "SPEC_CONTENT=$SPEC_CONTENT" \
    "CURRENT_FILE=$STATE_FILE" \
    "PINNED_CONTEXT=$PINNED_CONTEXT" \
    "README_INSTRUCTIONS=$README_INSTRUCTIONS" \
    "EXIT_SIGNALS=")
fi

LOG="$RALPH_DIR/logs/todo-$(date +%Y%m%d-%H%M%S).log"

echo "=== Creating Task Breakdown ==="
echo ""
# Use stream-json for real-time output display with configurable visibility
export PROMPT_CONTENT
run_claude_stream "PROMPT_CONTENT" "$LOG" "$CONFIG"

# Check for completion by examining the result in the JSON log
if jq -e 'select(.type == "result") | .result | contains("RALPH_COMPLETE")' "$LOG" >/dev/null 2>&1; then
  echo ""
  echo "Molecule creation complete!"

  FINAL_SPEC_PATH="$SPECS_DIR/$LABEL.md"

  # In update mode, merge new requirements into spec and cleanup state file
  if [ "$UPDATE_MODE" = "true" ] && [ -f "$NEW_REQUIREMENTS_PATH" ]; then
    echo ""
    echo "Merging new requirements into $FINAL_SPEC_PATH..."

    # Append new requirements to spec file (Claude should have already done this,
    # but we ensure the state file content is captured if not)
    if [ -f "$FINAL_SPEC_PATH" ]; then
      # Check if new requirements are already in the spec (Claude may have merged)
      # by looking for a unique marker from the new requirements
      FIRST_REQ_LINE=$(head -5 "$NEW_REQUIREMENTS_PATH" | grep -v '^#' | grep -v '^$' | head -1 || true)
      if [ -n "$FIRST_REQ_LINE" ] && ! grep -qF "$FIRST_REQ_LINE" "$FINAL_SPEC_PATH" 2>/dev/null; then
        echo ""
        echo "  (appending new requirements that weren't merged by Claude)"
        {
          echo ""
          echo "## Updates"
          echo ""
          cat "$NEW_REQUIREMENTS_PATH"
        } >> "$FINAL_SPEC_PATH"
      fi
    fi

    # Delete the state file after successful processing
    echo "  Cleaning up $NEW_REQUIREMENTS_PATH..."
    rm -f "$NEW_REQUIREMENTS_PATH"
  else
    # New spec mode: strip Implementation Notes section if present
    if [ -f "$SPEC_PATH" ]; then
      SPEC_CONTENT=$(cat "$SPEC_PATH")
      FINAL_CONTENT=$(strip_implementation_notes "$SPEC_CONTENT")

      if [ "$SPEC_CONTENT" != "$FINAL_CONTENT" ]; then
        echo ""
        echo "Stripping Implementation Notes from $FINAL_SPEC_PATH..."
        echo "$FINAL_CONTENT" > "$FINAL_SPEC_PATH"
      fi
    fi
  fi

  # Commit the spec file
  if [ -f "$FINAL_SPEC_PATH" ]; then
    echo ""
    echo "Committing spec..."
    git add "$FINAL_SPEC_PATH" "$SPECS_README" 2>/dev/null || true
    if git diff --cached --quiet 2>/dev/null; then
      echo "  (no changes to commit)"
    else
      COMMIT_MSG="Add $LABEL specification"
      if [ "$UPDATE_MODE" = "true" ]; then
        COMMIT_MSG="Update $LABEL specification"
      fi
      git commit -m "$COMMIT_MSG" >/dev/null 2>&1 && echo "  Committed: $FINAL_SPEC_PATH" || echo "  (commit failed or nothing to commit)"
    fi
  fi

  # Display the molecule ID if available
  STORED_MOLECULE=$(jq -r '.molecule // empty' "$STATE_FILE" 2>/dev/null || true)
  if [ -n "$STORED_MOLECULE" ]; then
    echo ""
    echo "Molecule ID: $STORED_MOLECULE"
    echo ""
    echo "To view molecule progress:"
    echo "  bd mol progress $STORED_MOLECULE"
  fi

  echo ""
  echo "To list created issues:"
  echo "  bd list -l spec-$LABEL"
  echo ""
  echo "To work through issues:"
  echo "  ralph run         # Work all issues automatically"
  echo "  ralph run --once  # Work one issue at a time"
else
  echo ""
  echo "Molecule creation did not complete. Review log: $LOG"
  echo "To retry: ralph todo"
fi
