#!/usr/bin/env bash
set -euo pipefail

# ralph diff [template-name]
# Shows local template changes vs packaged templates
# - No args: diff all templates
# - With name: diff specific template (e.g., "step", "plan", "ready")
# Output is pipeable to 'ralph tune' for integration mode

# Load shared helpers
# shellcheck source=util.sh
source "$(dirname "$0")/util.sh"

RALPH_DIR="${RALPH_DIR:-.ralph}"

# Template directory: use RALPH_TEMPLATE_DIR if set and exists
if [ -n "${RALPH_TEMPLATE_DIR:-}" ] && [ -d "$RALPH_TEMPLATE_DIR" ]; then
  PACKAGED_DIR="$RALPH_TEMPLATE_DIR"
else
  PACKAGED_DIR=""
fi

# Templates to compare (base names without .md)
TEMPLATES=("plan" "ready" "step" "config")

# Parse arguments
TEMPLATE_NAME="${1:-}"

show_usage() {
  echo "Usage: ralph diff [template-name]"
  echo ""
  echo "Shows local template changes vs packaged templates."
  echo ""
  echo "Arguments:"
  echo "  template-name  Optional: diff specific template (plan, ready, step, config)"
  echo "                 If omitted, diffs all templates"
  echo ""
  echo "Examples:"
  echo "  ralph diff           # Show all template changes"
  echo "  ralph diff step      # Show step.md changes only"
  echo "  ralph diff | ralph tune  # Pipe to tune for integration mode"
  echo ""
  echo "Environment:"
  echo "  RALPH_DIR           Ralph directory (default: .ralph)"
  echo "  RALPH_TEMPLATE_DIR  Packaged template directory (from nix develop)"
  echo ""
  echo "Local templates are at: \$RALPH_DIR/template/"
}

# Check for help flag
if [ "$TEMPLATE_NAME" = "-h" ] || [ "$TEMPLATE_NAME" = "--help" ]; then
  show_usage
  exit 0
fi

# Validate RALPH_TEMPLATE_DIR is set
if [ -z "$PACKAGED_DIR" ]; then
  error "RALPH_TEMPLATE_DIR not set or directory doesn't exist.

Run from 'nix develop' shell which sets RALPH_TEMPLATE_DIR.
Current value: ${RALPH_TEMPLATE_DIR:-<not set>}"
fi

# Validate local ralph directory exists
if [ ! -d "$RALPH_DIR" ]; then
  echo "No local templates found at $RALPH_DIR"
  echo "Run 'ralph plan <label>' first to initialize local templates."
  exit 0
fi

# If specific template requested, validate it
if [ -n "$TEMPLATE_NAME" ]; then
  # Normalize: remove .md or .nix suffix if provided
  TEMPLATE_NAME="${TEMPLATE_NAME%.md}"
  TEMPLATE_NAME="${TEMPLATE_NAME%.nix}"

  valid=false
  for t in "${TEMPLATES[@]}"; do
    if [ "$t" = "$TEMPLATE_NAME" ]; then
      valid=true
      break
    fi
  done

  if [ "$valid" = "false" ]; then
    error "Unknown template: $TEMPLATE_NAME

Valid templates: ${TEMPLATES[*]}"
  fi

  # Only diff the requested template
  TEMPLATES=("$TEMPLATE_NAME")
fi

# Get file extension for template
get_extension() {
  local name="$1"
  if [ "$name" = "config" ]; then
    echo ".nix"
  else
    echo ".md"
  fi
}

# Perform diff and collect results
has_changes=false
diff_output=""

for template in "${TEMPLATES[@]}"; do
  ext=$(get_extension "$template")
  local_file="$RALPH_DIR/template/${template}${ext}"
  packaged_file="$PACKAGED_DIR/${template}${ext}"

  # Skip if local file doesn't exist (not customized)
  if [ ! -f "$local_file" ]; then
    debug "Skipping $template: no local file"
    continue
  fi

  # Skip if packaged file doesn't exist (shouldn't happen)
  if [ ! -f "$packaged_file" ]; then
    warn "Packaged template not found: $packaged_file"
    continue
  fi

  # Compare files
  if ! diff -q "$packaged_file" "$local_file" >/dev/null 2>&1; then
    has_changes=true

    # Generate unified diff with header
    # Use labels to make output clearer
    diff_result=$(diff -u \
      --label "packaged/${template}${ext}" \
      --label "local/${template}${ext}" \
      "$packaged_file" "$local_file" 2>/dev/null || true)

    if [ -n "$diff_result" ]; then
      diff_output+="
### Template: ${template}${ext}
\`\`\`diff
$diff_result
\`\`\`
"
    fi
  else
    debug "$template: no changes"
  fi
done

# Output results
if [ "$has_changes" = "true" ]; then
  echo "# Local Template Changes"
  echo ""
  echo "Comparing local templates (\`$RALPH_DIR\`) against packaged templates (\`$PACKAGED_DIR\`)."
  echo "$diff_output"

  # Hint for integration mode (only if stdout is a tty)
  if [ -t 1 ]; then
    echo ""
    echo "---"
    echo "Pipe to 'ralph tune' for interactive integration:"
    echo "  ralph diff | ralph tune"
  fi
else
  if [ -n "$TEMPLATE_NAME" ]; then
    echo "No changes in ${TEMPLATE_NAME}$(get_extension "$TEMPLATE_NAME")"
  else
    echo "No local template changes found."
    echo ""
    echo "Local templates match packaged templates."
  fi
fi
