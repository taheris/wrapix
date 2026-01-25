#!/usr/bin/env bash
set -euo pipefail

# ralph start [label]
# Sets up for a new feature with optional label
# - Creates specs/ directory if needed
# - Creates specs/README.md from template if not exists
# - Clears previous plan state
# - Sets label in state (random if not provided)

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
TEMPLATE="${RALPH_TEMPLATE_DIR:-/etc/wrapix/ralph-template}"
SPECS_DIR="specs"

# Get label from argument or generate random 6-char
LABEL="${1:-$(head -c 6 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 6)}"

# Ensure ralph directory structure exists
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
SPECS_README="$SPECS_DIR/README.md"
if [ ! -f "$SPECS_README" ]; then
  SPECS_TEMPLATE="$TEMPLATE/specs-readme.md"
  if [ -f "$SPECS_TEMPLATE" ]; then
    cp "$SPECS_TEMPLATE" "$SPECS_README"
    echo "Created $SPECS_README from template"
  else
    # Fallback: create minimal README
    cat > "$SPECS_README" << 'EOF'
# Project Specifications

| Spec | Code | Purpose |
|------|------|---------|

EOF
    echo "Created minimal $SPECS_README"
  fi
fi

# Clear previous state (but preserve prompts and config)
rm -f "$RALPH_DIR/state/plan.md"
rm -f "$RALPH_DIR/state/label"
rm -f "$RALPH_DIR/state/spec"

# Set new label and spec name
echo "$LABEL" > "$RALPH_DIR/state/label"
echo "$LABEL" > "$RALPH_DIR/state/spec"
touch "$RALPH_DIR/state/plan.md"

echo ""
echo "Ralph started for feature: $LABEL"
echo ""
echo "State files:"
echo "  Label: $RALPH_DIR/state/label"
echo "  Spec:  $RALPH_DIR/state/spec"
echo ""
echo "Spec file will be created at: $SPECS_DIR/$LABEL.md"
echo ""
echo "Next steps:"
echo "  1. Run 'ralph plan' to conduct an interview and create the spec"
echo "  2. Run 'ralph ready' to convert spec to beads"
echo "  3. Run 'ralph step' or 'ralph loop' to work through issues"
