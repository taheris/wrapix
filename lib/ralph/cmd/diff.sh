#!/usr/bin/env bash
set -euo pipefail

# ralph diff [template-name]
# Shows local template changes vs packaged templates
# - No args: diff all templates
# - With name: diff specific template (e.g., "step", "plan", "todo")
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
# Main templates in .ralph/template/
TEMPLATES=(
  "plan"
  "plan-new"
  "plan-update"
  "todo"
  "todo-new"
  "todo-update"
  "step"
)

# Partials in .ralph/template/partial/
PARTIALS=(
  "context-pinning"
  "exit-signals"
  "spec-header"
)

# Parse arguments
TEMPLATE_NAME="${1:-}"

show_usage() {
  echo "Usage: ralph diff [template-name]"
  echo ""
  echo "Shows local template changes vs packaged templates."
  echo ""
  echo "Arguments:"
  echo "  template-name  Optional: diff specific template or partial"
  echo "                 If omitted, diffs all templates and partials"
  echo ""
  echo "Templates:"
  echo "  plan, plan-new, plan-update, todo, todo-new, todo-update, step"
  echo ""
  echo "Partials:"
  echo "  context-pinning, exit-signals, spec-header"
  echo ""
  echo "Examples:"
  echo "  ralph diff                    # Show all template changes"
  echo "  ralph diff step               # Show step.md changes only"
  echo "  ralph diff context-pinning    # Show partial changes"
  echo "  ralph diff | ralph tune       # Pipe to tune for integration mode"
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

# Track if we're diffing a specific partial
FILTER_PARTIAL=""

# If specific template requested, validate it
if [ -n "$TEMPLATE_NAME" ]; then
  # Normalize: remove .md suffix if provided
  TEMPLATE_NAME="${TEMPLATE_NAME%.md}"

  # Check if it's a template
  valid_template=false
  for t in "${TEMPLATES[@]}"; do
    if [ "$t" = "$TEMPLATE_NAME" ]; then
      valid_template=true
      break
    fi
  done

  # Check if it's a partial
  valid_partial=false
  for p in "${PARTIALS[@]}"; do
    if [ "$p" = "$TEMPLATE_NAME" ]; then
      valid_partial=true
      break
    fi
  done

  if [ "$valid_template" = "false" ] && [ "$valid_partial" = "false" ]; then
    error "Unknown template or partial: $TEMPLATE_NAME

Valid templates: ${TEMPLATES[*]}
Valid partials: ${PARTIALS[*]}"
  fi

  if [ "$valid_template" = "true" ]; then
    # Only diff the requested template
    TEMPLATES=("$TEMPLATE_NAME")
    PARTIALS=()
  else
    # Only diff the requested partial
    TEMPLATES=()
    FILTER_PARTIAL="$TEMPLATE_NAME"
  fi
fi

# All templates and partials are markdown
get_extension() {
  echo ".md"
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

# Diff partials
diff_partial() {
  local partial="$1"
  local local_file="$RALPH_DIR/template/partial/${partial}.md"
  local packaged_file="$PACKAGED_DIR/partial/${partial}.md"

  # Skip if local file doesn't exist (not customized)
  if [ ! -f "$local_file" ]; then
    debug "Skipping partial/$partial: no local file"
    return
  fi

  # Skip if packaged file doesn't exist (shouldn't happen)
  if [ ! -f "$packaged_file" ]; then
    warn "Packaged partial not found: $packaged_file"
    return
  fi

  # Compare files
  if ! diff -q "$packaged_file" "$local_file" >/dev/null 2>&1; then
    has_changes=true

    # Generate unified diff with header
    local diff_result
    diff_result=$(diff -u \
      --label "packaged/partial/${partial}.md" \
      --label "local/partial/${partial}.md" \
      "$packaged_file" "$local_file" 2>/dev/null || true)

    if [ -n "$diff_result" ]; then
      diff_output+="
### Partial: partial/${partial}.md
\`\`\`diff
$diff_result
\`\`\`
"
    fi
  else
    debug "partial/$partial: no changes"
  fi
}

# Diff partials (either all or filtered)
if [ -n "$FILTER_PARTIAL" ]; then
  diff_partial "$FILTER_PARTIAL"
else
  for partial in "${PARTIALS[@]}"; do
    diff_partial "$partial"
  done
fi

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
