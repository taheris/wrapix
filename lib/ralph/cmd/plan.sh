#!/usr/bin/env bash
set -euo pipefail

# ralph plan <label>
# Combined feature initialization and spec interview
# - Sets up ralph directory structure if needed
# - Creates specs/ directory if needed
# - Sets label in state
# - Substitutes placeholders in templates at runtime (fresh each run)
# - Conducts interactive spec interview
# - Creates spec file

# Container detection: if not in container and wrapix is available, re-launch in container
# /etc/wrapix/claude-config.json only exists inside containers (baked into image)
if [ ! -f /etc/wrapix/claude-config.json ] && command -v wrapix &>/dev/null; then
  export RALPH_MODE=1
  export RALPH_CMD=plan
  export RALPH_ARGS="${*:-}"
  exec wrapix
fi

# Load shared helpers
# shellcheck source=util.sh
source "$(dirname "$0")/util.sh"

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
TEMPLATE="${RALPH_TEMPLATE_DIR:-/etc/wrapix/ralph-template}"
SPECS_DIR="specs"
SPECS_README="$SPECS_DIR/README.md"
CURRENT_FILE="$RALPH_DIR/state/current.json"

# Parse arguments
LABEL=""
SPEC_HIDDEN="false"
UPDATE_SPEC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--hidden)
      SPEC_HIDDEN="true"
      shift
      ;;
    -u|--update)
      if [ -z "${2:-}" ]; then
        echo "Error: --update requires a spec name"
        echo "Usage: ralph plan --update <spec>"
        exit 1
      fi
      UPDATE_SPEC="$2"
      shift 2
      ;;
    -*)
      echo "Error: Unknown option: $1"
      echo "Usage: ralph plan [--hidden|-h] [--update|-u <spec>] <label>"
      exit 1
      ;;
    *)
      if [ -z "$LABEL" ]; then
        LABEL="$1"
      else
        echo "Error: Too many arguments"
        echo "Usage: ralph plan [--hidden|-h] [--update|-u <spec>] <label>"
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate mutually exclusive options
if [ -n "$UPDATE_SPEC" ] && [ "$SPEC_HIDDEN" = "true" ]; then
  echo "Error: --hidden and --update cannot be combined"
  echo "  --hidden creates a new spec in state/"
  echo "  --update modifies an existing spec in specs/"
  exit 1
fi

# Handle --update mode: validate spec exists and set label
if [ -n "$UPDATE_SPEC" ]; then
  UPDATE_SPEC_PATH="$SPECS_DIR/$UPDATE_SPEC.md"
  if [ ! -f "$UPDATE_SPEC_PATH" ]; then
    echo "Error: Spec not found: $UPDATE_SPEC_PATH"
    echo "Available specs in $SPECS_DIR/:"
    found_specs=false
    for spec_file in "$SPECS_DIR"/*.md; do
      [ -f "$spec_file" ] || continue
      found_specs=true
      basename "$spec_file" .md | sed 's/^/  /'
    done
    [ "$found_specs" = "true" ] || echo "  (none)"
    exit 1
  fi
  # In update mode, use the spec name as the label
  LABEL="$UPDATE_SPEC"
fi

# If no argument provided, try to read from state file
if [ -z "$LABEL" ] && [ -f "$CURRENT_FILE" ]; then
  LABEL=$(jq -r '.label // empty' "$CURRENT_FILE" 2>/dev/null || true)
  SPEC_HIDDEN=$(jq -r '.hidden // false' "$CURRENT_FILE" 2>/dev/null || echo "false")
fi

# Label is required (unless --update was used, which sets it)
if [ -z "$LABEL" ]; then
  echo "Error: Label is required"
  echo "Usage: ralph plan [--hidden|-h] [--update|-u <spec>] <label>"
  echo ""
  echo "Options:"
  echo "  -h, --hidden        Store spec in state/ instead of specs/"
  echo "  -u, --update <spec> Update an existing spec in specs/"
  echo ""
  echo "Example: ralph plan user-auth"
  echo "         ralph plan --hidden internal-tool"
  echo "         ralph plan --update sandbox"
  echo ""
  echo "Or resume an existing plan by running 'ralph plan' after 'ralph plan <label>' was run."
  exit 1
fi

# Ensure ralph directory structure exists (idempotent)
if [ ! -d "$RALPH_DIR" ]; then
  if [ ! -d "$TEMPLATE" ]; then
    echo "Error: Template directory not found at $TEMPLATE"
    echo "This usually means ralph is not properly installed."
    exit 1
  fi

  mkdir -p "$(dirname "$RALPH_DIR")"
  cp -r "$TEMPLATE" "$RALPH_DIR"
  # Fix permissions - Nix store files may be read-only
  chmod -R u+rwX "$RALPH_DIR"
  echo "Initialized ralph at $RALPH_DIR"
fi

# Ensure required directories exist
mkdir -p "$RALPH_DIR/history" "$RALPH_DIR/logs" "$RALPH_DIR/state"

# Create specs directory if not exists
if [ ! -d "$SPECS_DIR" ]; then
  mkdir -p "$SPECS_DIR"
  echo "Created $SPECS_DIR directory"
fi

# Create specs/README.md from template if not exists (never overwrite)
if [ ! -f "$SPECS_README" ]; then
  cat > "$SPECS_README" << 'EOF'
# Project Specifications

| Spec | Code | Purpose |
|------|------|---------|

## Terminology Index

| Term | Definition |
|------|------------|
EOF
  echo "Created $SPECS_README"
fi

# Set/update state in current.json
jq -n --arg label "$LABEL" --argjson hidden "$SPEC_HIDDEN" \
  '{label: $label, hidden: $hidden}' > "$CURRENT_FILE"

CONFIG_FILE="$RALPH_DIR/config.nix"

# Load config to compute derived values
CONFIG=$(nix eval --json --file "$CONFIG_FILE")
DEFAULT_PRIORITY=$(echo "$CONFIG" | jq -r '.beads.priority // 2')

# Compute spec path and README instructions based on hidden flag
if [ "$SPEC_HIDDEN" = "true" ]; then
  SPEC_PATH="$RALPH_DIR/state/$LABEL.md"
  README_INSTRUCTIONS=""
  README_UPDATE_SECTION=""
else
  SPEC_PATH="$SPECS_DIR/$LABEL.md"
  README_INSTRUCTIONS="5. **Update specs/README.md** with the epic bead ID"
  README_UPDATE_SECTION="## Update specs/README.md

After creating the epic, update the WIP table entry with the bead ID:
\`\`\`markdown
| [$LABEL.md](./$LABEL.md) | beads-XXXXXX | Brief purpose |
\`\`\`"
fi

# Read template and substitute ALL placeholders at runtime (fresh each time)
PROMPT_TEMPLATE="$RALPH_DIR/plan.md"
if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "Error: Plan prompt template not found: $PROMPT_TEMPLATE"
  echo "Make sure plan.md exists in your ralph directory."
  exit 1
fi

# Validate template has placeholders, reset from source if corrupted
validate_template "$PROMPT_TEMPLATE" "$TEMPLATE/plan.md" "plan.md"

# Pin context from specs/README.md
PINNED_CONTEXT=""
if [ -f "$SPECS_README" ]; then
  PINNED_CONTEXT=$(cat "$SPECS_README")
fi

# Check if we're continuing an existing spec
EXISTING_SPEC=""
CONTINUATION_CONTEXT=""
if [ -f "$SPEC_PATH" ]; then
  EXISTING_SPEC=$(cat "$SPEC_PATH")
  CONTINUATION_CONTEXT="

---

## Continuing Existing Plan

You are continuing work on an existing specification. Here is the current content of \`$SPEC_PATH\`:

\`\`\`markdown
$EXISTING_SPEC
\`\`\`

Review this spec with the user. They may want to:
- Continue refining incomplete sections
- Add new requirements
- Clarify existing points
- Finalize and proceed to implementation

Ask the user what they'd like to work on."
  echo "Continuing existing plan..."
  echo "  Label: $LABEL"
  echo "  Spec: $SPEC_PATH (exists)"
  echo "  Hidden: $SPEC_HIDDEN"
else
  echo "Starting new plan..."
  echo "  Label: $LABEL"
  echo "  Spec: $SPEC_PATH"
  echo "  Hidden: $SPEC_HIDDEN"
fi
echo ""

# Read template content
PROMPT_CONTENT=$(cat "$PROMPT_TEMPLATE")

# Substitute all placeholders at runtime (this is the key fix - fresh substitution each time)
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{LABEL\}\}/$LABEL}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{SPEC_PATH\}\}/$SPEC_PATH}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{PRIORITY\}\}/$DEFAULT_PRIORITY}"

# Multi-line substitutions using awk
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v replacement="$README_INSTRUCTIONS" '{gsub(/\{\{README_INSTRUCTIONS\}\}/, replacement); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v replacement="$README_UPDATE_SECTION" '{gsub(/\{\{README_UPDATE_SECTION\}\}/, replacement); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$PINNED_CONTEXT" '{gsub(/\{\{PINNED_CONTEXT\}\}/, ctx); print}')

# Append continuation context if resuming an existing spec
PROMPT_CONTENT="${PROMPT_CONTENT}${CONTINUATION_CONTEXT}"

# Open interactive Claude console with the plan prompt
export PROMPT_CONTENT
run_claude_interactive "PROMPT_CONTENT"

echo ""
echo "Next steps:"
echo "  1. Review the spec: cat $SPEC_PATH"
echo "  2. Convert to beads: ralph ready"
