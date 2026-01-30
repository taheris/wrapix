#!/usr/bin/env bash
set -euo pipefail

# ralph check - Validate all templates
# Checks:
# - Partial files exist
# - Body files parse correctly
# - No syntax errors in Nix expressions
# - Dry-run render with dummy values to catch placeholder typos
#
# Exit codes: 0 = valid, 1 = errors (with details)

# Load shared helpers
# shellcheck source=util.sh
source "$(dirname "$0")/util.sh"

# Template directory: use RALPH_TEMPLATE_DIR if set and exists
if [ -n "${RALPH_TEMPLATE_DIR:-}" ] && [ -d "$RALPH_TEMPLATE_DIR" ]; then
  TEMPLATE_DIR="$RALPH_TEMPLATE_DIR"
else
  TEMPLATE_DIR=""
fi

# Track errors
ERRORS=()

show_usage() {
  echo "Usage: ralph check"
  echo ""
  echo "Validates all ralph templates:"
  echo "  - Partial files exist"
  echo "  - Body files parse correctly"
  echo "  - No syntax errors in Nix expressions"
  echo "  - Dry-run render with dummy values"
  echo ""
  echo "Exit codes:"
  echo "  0  All templates valid"
  echo "  1  Errors found (details printed)"
  echo ""
  echo "Environment:"
  echo "  RALPH_TEMPLATE_DIR  Template directory (from nix develop)"
}

# Check for help flag
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  show_usage
  exit 0
fi

# Validate RALPH_TEMPLATE_DIR is set
if [ -z "$TEMPLATE_DIR" ]; then
  error "RALPH_TEMPLATE_DIR not set or directory doesn't exist.

Run from 'nix develop' shell which sets RALPH_TEMPLATE_DIR.
Current value: ${RALPH_TEMPLATE_DIR:-<not set>}"
fi

echo "Checking templates in: $TEMPLATE_DIR"
echo ""

#-----------------------------------------------------------------------------
# Check 1: Partial files exist
#-----------------------------------------------------------------------------
echo "Checking partials..."

PARTIAL_DIR="$TEMPLATE_DIR/partial"
EXPECTED_PARTIALS=("context-pinning.md" "exit-signals.md" "spec-header.md")

for partial in "${EXPECTED_PARTIALS[@]}"; do
  partial_path="$PARTIAL_DIR/$partial"
  if [ -f "$partial_path" ]; then
    echo "  ✓ $partial"
  else
    echo "  ✗ $partial (missing)"
    ERRORS+=("Missing partial: $partial_path")
  fi
done

#-----------------------------------------------------------------------------
# Check 2: Body files exist and are readable
#-----------------------------------------------------------------------------
echo ""
echo "Checking body files..."

BODY_FILES=("plan-new.md" "plan-update.md" "ready-new.md" "ready-update.md" "step.md")

for body in "${BODY_FILES[@]}"; do
  body_path="$TEMPLATE_DIR/$body"
  if [ -f "$body_path" ]; then
    # Check it's readable
    if head -1 "$body_path" >/dev/null 2>&1; then
      echo "  ✓ $body"
    else
      echo "  ✗ $body (unreadable)"
      ERRORS+=("Unreadable body file: $body_path")
    fi
  else
    echo "  ✗ $body (missing)"
    ERRORS+=("Missing body file: $body_path")
  fi
done

#-----------------------------------------------------------------------------
# Check 3: Nix expressions are valid
#-----------------------------------------------------------------------------
echo ""
echo "Checking Nix expressions..."

NIX_FILE="$TEMPLATE_DIR/default.nix"

if [ -f "$NIX_FILE" ]; then
  # Try to parse the Nix file
  if nix-instantiate --parse "$NIX_FILE" >/dev/null 2>&1; then
    echo "  ✓ default.nix (syntax valid)"
  else
    echo "  ✗ default.nix (syntax error)"
    # Capture the actual error
    parse_error=$(nix-instantiate --parse "$NIX_FILE" 2>&1 || true)
    ERRORS+=("Nix syntax error in $NIX_FILE: $parse_error")
  fi

  # Try to evaluate the template module using nix eval with flake
  # This is more robust in flake environments
  if nix eval --impure --expr "let lib = (builtins.getFlake \"nixpkgs\").lib; t = import $NIX_FILE { inherit lib; }; in t.validateTemplates" >/dev/null 2>&1; then
    echo "  ✓ default.nix (evaluation valid)"
  else
    echo "  ✗ default.nix (evaluation error)"
    eval_error=$(nix eval --impure --expr "let lib = (builtins.getFlake \"nixpkgs\").lib; t = import $NIX_FILE { inherit lib; }; in t.validateTemplates" 2>&1 || true)
    ERRORS+=("Nix evaluation error: $eval_error")
  fi
else
  echo "  ✗ default.nix (missing)"
  ERRORS+=("Missing Nix file: $NIX_FILE")
fi

# Check config.nix if present
CONFIG_FILE="$TEMPLATE_DIR/config.nix"
if [ -f "$CONFIG_FILE" ]; then
  if nix-instantiate --parse "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "  ✓ config.nix (syntax valid)"
  else
    echo "  ✗ config.nix (syntax error)"
    parse_error=$(nix-instantiate --parse "$CONFIG_FILE" 2>&1 || true)
    ERRORS+=("Nix syntax error in $CONFIG_FILE: $parse_error")
  fi
fi

#-----------------------------------------------------------------------------
# Check 4: Partial references are valid
#-----------------------------------------------------------------------------
echo ""
echo "Checking partial references..."

for body in "${BODY_FILES[@]}"; do
  body_path="$TEMPLATE_DIR/$body"
  [ -f "$body_path" ] || continue

  # Extract partial references {{> partial-name}}
  # Use grep to find references, then extract the partial names
  refs=$(grep -oE '\{\{> [a-z-]+\}\}' "$body_path" 2>/dev/null | sed 's/{{> //;s/}}//' || true)

  if [ -n "$refs" ]; then
    for ref in $refs; do
      partial_path="$PARTIAL_DIR/${ref}.md"
      if [ -f "$partial_path" ]; then
        echo "  ✓ $body → {{> $ref}}"
      else
        echo "  ✗ $body → {{> $ref}} (partial missing)"
        ERRORS+=("$body references missing partial: $ref")
      fi
    done
  fi
done

#-----------------------------------------------------------------------------
# Check 5: Dry-run render with dummy values
#-----------------------------------------------------------------------------
echo ""
echo "Checking template rendering..."

# Build dummy variables for dry-run render
# This catches typos in variable names
# We test each template individually to get better error messages
TEMPLATES_TO_CHECK=("plan-new" "plan-update" "ready-new" "ready-update" "step")

for template in "${TEMPLATES_TO_CHECK[@]}"; do
  # Build template-specific render expression using nix eval with flake
  render_expr='
let
  lib = (builtins.getFlake "nixpkgs").lib;
  templates = (import '"$NIX_FILE"' { inherit lib; }).templates;
  template = templates."'"$template"'";

  # Dummy values for all known variables
  dummyVars = {
    PINNED_CONTEXT = "dummy-pinned-context";
    LABEL = "dummy-label";
    SPEC_PATH = "specs/dummy.md";
    SPEC_CONTENT = "# Dummy Spec Content";
    EXISTING_SPEC = "# Existing Spec";
    MOLECULE_ID = "test-mol123";
    MOLECULE_PROGRESS = "50% (5/10)";
    NEW_REQUIREMENTS = "- New requirement 1";
    ISSUE_ID = "test-issue123";
    TITLE = "Dummy Task Title";
    DESCRIPTION = "Dummy task description";
    EXIT_SIGNALS = "- RALPH_COMPLETE";
  };

  # Filter dummyVars to only include variables this template needs
  templateVars = lib.filterAttrs (k: v: builtins.elem k template.variables) dummyVars;

  # Render the template - this will throw if there are issues
  rendered = template.render templateVars;

# Return length of rendered content (proves it worked without outputting huge string)
in builtins.stringLength rendered
'

  if nix eval --impure --expr "$render_expr" >/dev/null 2>&1; then
    echo "  ✓ $template (renders successfully)"
  else
    echo "  ✗ $template (render failed)"
    render_error=$(nix eval --impure --expr "$render_expr" 2>&1 || true)
    ERRORS+=("Template $template render failed: $render_error")
  fi
done

#-----------------------------------------------------------------------------
# Check 6: Variable placeholders in body files match declarations
#-----------------------------------------------------------------------------
echo ""
echo "Checking variable declarations..."

# Create a temporary Nix file for the variable check expression
# This avoids shell escaping issues with the regex pattern
VAR_CHECK_NIX=$(mktemp)
# shellcheck disable=SC2064
trap "rm -f $VAR_CHECK_NIX" EXIT

cat > "$VAR_CHECK_NIX" << 'NIXEOF'
let
  lib = (builtins.getFlake "nixpkgs").lib;
  nixFile = builtins.getEnv "RALPH_CHECK_NIX_FILE";
  templates = (import nixFile { inherit lib; }).templates;

  # Extract {{VAR}} patterns from content (excluding {{> partial}})
  # Uses POSIX extended regex - braces must be escaped with [{}]
  extractVars = content:
    let
      parts = builtins.split "[{][{]([A-Z_]+)[}][}]" content;
      matches = builtins.filter (p: builtins.isList p) parts;
    in
    map builtins.head matches;

  results = builtins.mapAttrs (name: template:
    let
      # Get declared variables
      declared = template.variables;
      # Get variables used in content (after partial resolution)
      usedInBody = extractVars template.content;
      # Variables from partials
      partialVars = builtins.concatLists (map extractVars (builtins.attrValues template.partials));
      allUsed = usedInBody ++ partialVars;
      # Find undeclared variables (used but not declared)
      undeclared = builtins.filter (v: !(builtins.elem v declared)) allUsed;
    in
    { inherit declared undeclared; usedInBody = usedInBody; }
  ) templates;
in results
NIXEOF

if var_check=$(RALPH_CHECK_NIX_FILE="$NIX_FILE" nix eval --impure --json --file "$VAR_CHECK_NIX" 2>/dev/null); then
  for template in plan-new plan-update ready-new ready-update step; do
    undeclared=$(echo "$var_check" | jq -r ".\"$template\".undeclared | length" 2>/dev/null)
    if [ "$undeclared" = "0" ]; then
      echo "  ✓ $template (all variables declared)"
    else
      undeclared_list=$(echo "$var_check" | jq -r ".\"$template\".undeclared | join(\", \")" 2>/dev/null)
      echo "  ⚠ $template (undeclared variables: $undeclared_list)"
      # This is a warning, not an error - partials may use variables not in template.variables
    fi
  done
else
  echo "  ⚠ Variable check skipped (evaluation failed)"
fi

#-----------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------
echo ""
echo "─────────────────────────────────────"

if [ ${#ERRORS[@]} -eq 0 ]; then
  echo "✓ All checks passed"
  exit 0
else
  echo "✗ ${#ERRORS[@]} error(s) found:"
  echo ""
  for err in "${ERRORS[@]}"; do
    echo "  • $err"
  done
  exit 1
fi
