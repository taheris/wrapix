#!/usr/bin/env bash
set -euo pipefail

# ralph ready
# Converts spec to beads with task breakdown
# - Pins context by reading specs/README.md
# - Reads current spec from state
# - Analyzes spec and creates task breakdown
# - Creates parent/epic bead, then child tasks
# - Updates specs/README.md WIP table with parent bead ID
# - Finalizes spec to specs/ (stripping Implementation Notes section)

# Container detection: if not in container and wrapix is available, re-launch in container
# /etc/wrapix/claude-config.json only exists inside containers (baked into image)
if [ ! -f /etc/wrapix/claude-config.json ] && command -v wrapix &>/dev/null; then
  export RALPH_MODE=1
  export RALPH_CMD=ready
  export RALPH_ARGS="${*:-}"
  exec wrapix
fi

# Load shared helpers
# shellcheck source=util.sh
source "$(dirname "$0")/util.sh"

RALPH_DIR="${RALPH_DIR:-.ralph}"

# Template directory: use RALPH_TEMPLATE_DIR if set and exists
if [ -n "${RALPH_TEMPLATE_DIR:-}" ] && [ -d "$RALPH_TEMPLATE_DIR" ]; then
  TEMPLATE="$RALPH_TEMPLATE_DIR"
else
  TEMPLATE=""
fi
CONFIG_FILE="$RALPH_DIR/config.nix"
SPECS_DIR="specs"
SPECS_README="$SPECS_DIR/README.md"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: No ralph config found at $CONFIG_FILE"
  echo "Run 'ralph plan <label>' first."
  exit 1
fi

# Get label, hidden flag, and update mode from state
CURRENT_FILE="$RALPH_DIR/state/current.json"
if [ ! -f "$CURRENT_FILE" ]; then
  echo "Error: No current.json found. Run 'ralph plan <label>' first."
  exit 1
fi
LABEL=$(jq -r '.label // empty' "$CURRENT_FILE")
SPEC_HIDDEN=$(jq -r '.hidden // false' "$CURRENT_FILE")
UPDATE_MODE=$(jq -r '.update // false' "$CURRENT_FILE")

if [ -z "$LABEL" ]; then
  echo "Error: No label in current.json. Run 'ralph plan <label>' first."
  exit 1
fi

# Load config to get priority
CONFIG=$(nix eval --json --file "$CONFIG_FILE")
DEFAULT_PRIORITY=$(echo "$CONFIG" | jq -r '.beads.priority // 2')

# Compute spec path based on hidden flag
if [ "$SPEC_HIDDEN" = "true" ]; then
  SPEC_PATH="$RALPH_DIR/state/$LABEL.md"
else
  SPEC_PATH="$SPECS_DIR/$LABEL.md"
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
    echo "which ralph ready will then process."
    exit 0
  fi
  NEW_REQUIREMENTS=$(cat "$NEW_REQUIREMENTS_PATH")
fi

# Select template based on mode: ready-new.md for new specs, ready-update.md for updates
if [ "$UPDATE_MODE" = "true" ]; then
  TEMPLATE_NAME="ready-update.md"
else
  TEMPLATE_NAME="ready-new.md"
fi
PROMPT_TEMPLATE="$RALPH_DIR/template/$TEMPLATE_NAME"
if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "Error: Ready prompt template not found: $PROMPT_TEMPLATE"
  echo ""
  if [ -n "$TEMPLATE" ]; then
    echo "Copying from $TEMPLATE..."
    cp "$TEMPLATE/$TEMPLATE_NAME" "$PROMPT_TEMPLATE"
    chmod u+rw "$PROMPT_TEMPLATE"
  else
    echo "Make sure $TEMPLATE_NAME exists in your ralph template directory."
    exit 1
  fi
fi

# Validate template has placeholders, reset from source if corrupted
validate_template "$PROMPT_TEMPLATE" "$TEMPLATE/$TEMPLATE_NAME" "$TEMPLATE_NAME"

mkdir -p "$RALPH_DIR/logs"

# Pin context from specs/README.md
PINNED_CONTEXT=""
if [ -f "$SPECS_README" ]; then
  PINNED_CONTEXT=$(cat "$SPECS_README")
fi

# Extract title from spec file (first heading)
SPEC_TITLE=$(grep -m 1 '^#' "$SPEC_PATH" | sed 's/^#* *//' || echo "$SPEC_NAME")

# Get molecule ID from current.json (for update mode)
MOLECULE_ID=$(jq -r '.molecule // empty' "$CURRENT_FILE")

# Count existing tasks (for status display in update mode)
EXISTING_COUNT=0
if [ "$UPDATE_MODE" = "true" ]; then
  EXISTING_BEADS=$(bd list --label "spec-$LABEL" --format json 2>/dev/null || echo "[]")
  EXISTING_COUNT=$(echo "$EXISTING_BEADS" | jq 'length')
fi

echo "Ralph Ready: Converting spec to molecule..."
echo "  Label: $LABEL"
echo "  Spec: $SPEC_PATH"
echo "  Title: $SPEC_TITLE"
if [ "$UPDATE_MODE" = "true" ]; then
  if [ -n "$MOLECULE_ID" ]; then
    echo "  Mode: UPDATE (bonding new tasks to existing molecule)"
    echo "  Molecule: $MOLECULE_ID"
  else
    echo "  Mode: UPDATE (creating molecule for existing spec)"
  fi
  echo "  Existing tasks: $EXISTING_COUNT"
else
  echo "  Mode: NEW (creating molecule from scratch)"
fi
echo ""

# Read template content (placeholders are substituted at runtime)
PROMPT_CONTENT=$(cat "$PROMPT_TEMPLATE")

# Resolve partials ({{> partial-name}})
PROMPT_CONTENT=$(resolve_partials "$PROMPT_CONTENT" "$TEMPLATE/partial")

# Read existing spec content for template (for update mode context)
EXISTING_SPEC=""
if [ -f "$SPEC_PATH" ]; then
  EXISTING_SPEC=$(cat "$SPEC_PATH")
fi

# Substitute simple placeholders at runtime
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{LABEL\}\}/$LABEL}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{SPEC_PATH\}\}/$SPEC_PATH}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{PRIORITY\}\}/$DEFAULT_PRIORITY}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{SPEC_TITLE\}\}/$SPEC_TITLE}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{CURRENT_FILE\}\}/$CURRENT_FILE}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{EXIT_SIGNALS\}\}/}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{NEW_REQUIREMENTS_PATH\}\}/$NEW_REQUIREMENTS_PATH}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{MOLECULE_ID\}\}/$MOLECULE_ID}"

# Multi-line substitutions using awk (handles newlines in replacement text)
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$PINNED_CONTEXT" '{gsub(/{{PINNED_CONTEXT}}/, ctx); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$EXISTING_SPEC" '{gsub(/{{EXISTING_SPEC}}/, ctx); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$EXISTING_SPEC" '{gsub(/{{SPEC_CONTENT}}/, ctx); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$NEW_REQUIREMENTS" '{gsub(/{{NEW_REQUIREMENTS}}/, ctx); print}')

LOG="$RALPH_DIR/logs/ready-$(date +%Y%m%d-%H%M%S).log"

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
  STORED_MOLECULE=$(jq -r '.molecule // empty' "$CURRENT_FILE" 2>/dev/null || true)
  if [ -n "$STORED_MOLECULE" ]; then
    echo ""
    echo "Molecule ID: $STORED_MOLECULE"
    echo ""
    echo "To view molecule progress:"
    echo "  bd mol progress $STORED_MOLECULE"
  fi

  echo ""
  echo "To list created issues:"
  echo "  bd list --label spec-$LABEL"
  echo ""
  echo "To work through issues:"
  echo "  ralph step      # Work one issue at a time"
  echo "  ralph loop      # Work all issues automatically"
else
  echo ""
  echo "Molecule creation did not complete. Review log: $LOG"
  echo "To retry: ralph ready"
fi
