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

RALPH_DIR="${RALPH_DIR:-.wrapix/ralph}"

# Template directory: use RALPH_TEMPLATE_DIR if set and exists
if [ -n "${RALPH_TEMPLATE_DIR:-}" ] && [ -d "$RALPH_TEMPLATE_DIR" ]; then
  TEMPLATE="$RALPH_TEMPLATE_DIR"
else
  TEMPLATE=""
fi
SPECS_DIR="specs"
SPECS_README="$SPECS_DIR/README.md"
CURRENT_FILE="$RALPH_DIR/state/current.json"

# Parse arguments
LABEL=""
SPEC_NEW="false"
SPEC_HIDDEN="false"
UPDATE_SPEC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--new)
      SPEC_NEW="true"
      shift
      ;;
    -h|--hidden)
      SPEC_HIDDEN="true"
      shift
      ;;
    -u|--update)
      if [ -z "${2:-}" ]; then
        echo "Error: --update requires a spec name"
        echo "Usage: ralph plan -u <spec>"
        exit 1
      fi
      UPDATE_SPEC="$2"
      shift 2
      ;;
    -uh|-hu)
      # Combined flags: update + hidden
      if [ -z "${2:-}" ]; then
        echo "Error: -uh requires a spec name"
        echo "Usage: ralph plan -uh <spec>"
        exit 1
      fi
      SPEC_HIDDEN="true"
      UPDATE_SPEC="$2"
      shift 2
      ;;
    -*)
      echo "Error: Unknown option: $1"
      echo "Usage: ralph plan -n <label>           # New spec in specs/"
      echo "       ralph plan -h <label>           # New spec in state/ (hidden)"
      echo "       ralph plan -u <spec>            # Update existing spec"
      echo "       ralph plan -u -h <spec>         # Update existing hidden spec"
      exit 1
      ;;
    *)
      if [ -z "$LABEL" ]; then
        LABEL="$1"
      else
        echo "Error: Too many arguments"
        echo "Usage: ralph plan -n <label>           # New spec in specs/"
        echo "       ralph plan -h <label>           # New spec in state/ (hidden)"
        echo "       ralph plan -u <spec>            # Update existing spec"
        echo "       ralph plan -u -h <spec>         # Update existing hidden spec"
        exit 1
      fi
      shift
      ;;
  esac
done

# If a label was provided without a mode flag, error immediately
# (don't fall through to resume logic which would be confusing)
if [ -n "$LABEL" ] && [ "$SPEC_NEW" = "false" ] && [ "$SPEC_HIDDEN" = "false" ] && [ -z "$UPDATE_SPEC" ]; then
  echo "Error: Mode flag required when providing a label"
  echo ""
  echo "Usage: ralph plan -n <label>           # New spec in specs/"
  echo "       ralph plan -h <label>           # New spec in state/ (hidden)"
  echo "       ralph plan -u <spec>            # Update existing spec"
  echo "       ralph plan -u -h <spec>         # Update existing hidden spec"
  echo "       ralph plan                      # Resume previous plan session"
  exit 1
fi

# Validate mode flags: exactly one required, except -u and -h can combine
# Valid combinations:
#   -n only         -> new spec in specs/
#   -h only         -> new spec in state/
#   -u only         -> update spec in specs/
#   -u -h           -> update spec in state/
# Invalid:
#   -n -h           -> error
#   -n -u           -> error
#   no flag         -> error

if [ "$SPEC_NEW" = "true" ] && [ "$SPEC_HIDDEN" = "true" ]; then
  echo "Error: --new and --hidden cannot be combined"
  echo "  Use -n for new spec in specs/"
  echo "  Use -h for new spec in state/ (hidden)"
  exit 1
fi

if [ "$SPEC_NEW" = "true" ] && [ -n "$UPDATE_SPEC" ]; then
  echo "Error: --new and --update cannot be combined"
  echo "  Use -n for new spec"
  echo "  Use -u for updating existing spec"
  exit 1
fi

# Require at least one mode flag (unless resuming from state file)
if [ "$SPEC_NEW" = "false" ] && [ "$SPEC_HIDDEN" = "false" ] && [ -z "$UPDATE_SPEC" ]; then
  # Check if we can resume from state file
  if [ -f "$CURRENT_FILE" ]; then
    LABEL=$(jq -r '.label // empty' "$CURRENT_FILE" 2>/dev/null || true)
    if [ -n "$LABEL" ]; then
      # Resuming from state file - read the hidden and update flags too
      SPEC_HIDDEN=$(jq -r '.hidden // false' "$CURRENT_FILE" 2>/dev/null || echo "false")
      UPDATE_MODE=$(jq -r '.update // false' "$CURRENT_FILE" 2>/dev/null || echo "false")
      if [ "$UPDATE_MODE" = "true" ]; then
        UPDATE_SPEC="$LABEL"
      fi
    fi
  fi

  # If still no mode flag, error
  if [ "$SPEC_NEW" = "false" ] && [ "$SPEC_HIDDEN" = "false" ] && [ -z "$UPDATE_SPEC" ]; then
    echo "Error: Mode flag required"
    echo ""
    echo "Usage: ralph plan -n <label>           # New spec in specs/"
    echo "       ralph plan -h <label>           # New spec in state/ (hidden)"
    echo "       ralph plan -u <spec>            # Update existing spec"
    echo "       ralph plan -u -h <spec>         # Update existing hidden spec"
    echo ""
    echo "Or resume an existing plan by running 'ralph plan' after a previous session."
    exit 1
  fi
fi

# Handle --update mode: validate spec exists and set label
if [ -n "$UPDATE_SPEC" ]; then
  # Determine where to look for the spec based on -h flag
  if [ "$SPEC_HIDDEN" = "true" ]; then
    UPDATE_SPEC_PATH="$RALPH_DIR/state/$UPDATE_SPEC.md"
    SPEC_LOCATION="$RALPH_DIR/state/"
  else
    UPDATE_SPEC_PATH="$SPECS_DIR/$UPDATE_SPEC.md"
    SPEC_LOCATION="$SPECS_DIR/"
  fi

  if [ ! -f "$UPDATE_SPEC_PATH" ]; then
    echo "Error: Spec not found: $UPDATE_SPEC_PATH"
    echo "Available specs in $SPEC_LOCATION:"
    found_specs=false
    for spec_file in "$SPEC_LOCATION"*.md; do
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

# Label is required (unless --update was used, which sets it, or resuming from state)
if [ -z "$LABEL" ]; then
  echo "Error: Label is required"
  echo ""
  echo "Usage: ralph plan -n <label>           # New spec in specs/"
  echo "       ralph plan -h <label>           # New spec in state/ (hidden)"
  echo "       ralph plan -u <spec>            # Update existing spec"
  echo "       ralph plan -u -h <spec>         # Update existing hidden spec"
  echo ""
  echo "Examples:"
  echo "  ralph plan -n user-auth              # Create specs/user-auth.md"
  echo "  ralph plan -h internal-tool          # Create state/internal-tool.md (hidden)"
  echo "  ralph plan -u sandbox                # Update specs/sandbox.md"
  echo "  ralph plan -u -h internal-tool       # Update state/internal-tool.md"
  echo ""
  echo "Or resume an existing plan by running 'ralph plan' after a previous session."
  exit 1
fi

# Ensure ralph directory structure exists (idempotent)
if [ ! -d "$RALPH_DIR" ]; then
  if [ -z "$TEMPLATE" ]; then
    echo "Error: Cannot initialize ralph - RALPH_TEMPLATE_DIR not set or doesn't exist."
    [ -n "${RALPH_TEMPLATE_DIR:-}" ] && echo "  RALPH_TEMPLATE_DIR=$RALPH_TEMPLATE_DIR (not found)"
    echo ""
    echo "To fix this, do one of the following:"
    echo "  - Run 'ralph sync' to fetch templates from GitHub"
    echo "  - Set RALPH_TEMPLATE_DIR to point to an existing template directory"
    exit 1
  fi

  mkdir -p "$(dirname "$RALPH_DIR")"
  cp -r "$TEMPLATE" "$RALPH_DIR"
  # Fix permissions - Nix store files may be read-only
  chmod -R u+rwX "$RALPH_DIR"
  echo "Initialized ralph at $RALPH_DIR"
fi

# Ensure required directories exist
mkdir -p "$RALPH_DIR/history" "$RALPH_DIR/logs" "$RALPH_DIR/state" "$RALPH_DIR/template"

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
# Track whether this is an update to an existing spec (vs new spec)
UPDATE_MODE="false"
if [ -n "$UPDATE_SPEC" ]; then
  UPDATE_MODE="true"
fi

# In update mode, preserve existing molecule ID from current.json
EXISTING_MOLECULE=""
if [ "$UPDATE_MODE" = "true" ] && [ -f "$CURRENT_FILE" ]; then
  EXISTING_MOLECULE=$(jq -r '.molecule // empty' "$CURRENT_FILE" 2>/dev/null || true)
fi

# Build the new state JSON, preserving molecule if it exists
if [ -n "$EXISTING_MOLECULE" ]; then
  jq -n --arg label "$LABEL" --argjson hidden "$SPEC_HIDDEN" --argjson update "$UPDATE_MODE" --arg molecule "$EXISTING_MOLECULE" \
    '{label: $label, hidden: $hidden, update: $update, molecule: $molecule}' > "$CURRENT_FILE"
else
  jq -n --arg label "$LABEL" --argjson hidden "$SPEC_HIDDEN" --argjson update "$UPDATE_MODE" \
    '{label: $label, hidden: $hidden, update: $update}' > "$CURRENT_FILE"
fi

# Compute spec path and README instructions based on hidden flag
if [ "$SPEC_HIDDEN" = "true" ]; then
  SPEC_PATH="$RALPH_DIR/state/$LABEL.md"
  README_INSTRUCTIONS=""
else
  SPEC_PATH="$SPECS_DIR/$LABEL.md"
  README_INSTRUCTIONS="5. **Update specs/README.md** with the epic bead ID"
fi

# Path for new requirements in update mode (separate from main spec)
NEW_REQUIREMENTS_PATH="$RALPH_DIR/state/$LABEL.md"

# Select template based on mode: plan-new for new specs, plan-update for updates
if [ "$UPDATE_MODE" = "true" ]; then
  TEMPLATE_NAME="plan-update"
else
  TEMPLATE_NAME="plan-new"
fi

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

# Render template using centralized render_template function
# Variables differ based on template type
if [ "$UPDATE_MODE" = "true" ]; then
  PROMPT_CONTENT=$(render_template "$TEMPLATE_NAME" \
    "LABEL=$LABEL" \
    "SPEC_PATH=$SPEC_PATH" \
    "EXISTING_SPEC=$EXISTING_SPEC" \
    "NEW_REQUIREMENTS_PATH=$NEW_REQUIREMENTS_PATH" \
    "PINNED_CONTEXT=$PINNED_CONTEXT" \
    "EXIT_SIGNALS=")
else
  PROMPT_CONTENT=$(render_template "$TEMPLATE_NAME" \
    "LABEL=$LABEL" \
    "SPEC_PATH=$SPEC_PATH" \
    "README_INSTRUCTIONS=$README_INSTRUCTIONS" \
    "PINNED_CONTEXT=$PINNED_CONTEXT" \
    "EXIT_SIGNALS=")

  # Append continuation context if resuming an existing spec
  PROMPT_CONTENT="${PROMPT_CONTENT}${CONTINUATION_CONTEXT}"
fi

# Open interactive Claude console with the plan prompt
export PROMPT_CONTENT
run_claude_interactive "PROMPT_CONTENT"

echo ""
echo "Next steps:"
echo "  1. Review the spec: cat $SPEC_PATH"
echo "  2. Convert to beads: ralph todo"
