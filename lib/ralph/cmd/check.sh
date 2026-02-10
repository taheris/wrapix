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

To fix this, do one of the following:
  - Run 'ralph sync' to fetch templates from GitHub
  - Set RALPH_TEMPLATE_DIR to point to an existing template directory

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

BODY_FILES=("plan-new.md" "plan-update.md" "todo-new.md" "todo-update.md" "run.md")

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
# Dummy values are generated dynamically from variable metadata in default.nix

TEMPLATES_TO_CHECK=("plan-new" "plan-update" "todo-new" "todo-update" "run")

# Find flake root for lib access
FLAKE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$FLAKE_ROOT" ] || [ ! -f "$FLAKE_ROOT/flake.nix" ]; then
  echo "  ⚠ Not in a git repo with flake.nix, skipping template rendering check"
  FLAKE_ROOT=""
fi

# shellcheck disable=SC2016  # Single quotes are intentional for Nix expression building
for template in "${TEMPLATES_TO_CHECK[@]}"; do
  if [ -z "$FLAKE_ROOT" ]; then
    echo "  - $template (skipped - no flake)"
    continue
  fi

  # Build template-specific render expression using nix eval with flake
  # Reads variable definitions from Nix and generates dummy values based on metadata
  # Uses the local flake's nixpkgs input to get lib (no GitHub API calls)
  render_expr='
let
  flake = builtins.getFlake (toString '"$FLAKE_ROOT"');
  lib = flake.inputs.nixpkgs.lib;
  templateModule = import '"$NIX_FILE"' { inherit lib; };
  templates = templateModule.templates;
  variableDefs = templateModule.variableDefinitions;
  template = templates."'"$template"'";

  # Generate a dummy value for a variable based on its metadata
  # Uses source type, name, and other metadata to create appropriate dummy values
  makeDummy = name: def:
    let
      source = def.source or "unknown";
      lowerName = lib.toLower name;
    in
    if source == "args" then "dummy-${lowerName}"
    else if source == "state" then "dummy-state-${lowerName}"
    else if source == "computed" then
      if name == "SPEC_PATH" then "specs/dummy.md"
      else if name == "CURRENT_FILE" then ".wrapix/ralph/state/current.json"
      else if name == "NEW_REQUIREMENTS_PATH" then ".wrapix/ralph/state/dummy-feature.md"
      else if name == "MOLECULE_PROGRESS" then "50% (5/10)"
      else "dummy-computed-${lowerName}"
    else if source == "file" then "# Dummy content for ${name}"
    else if source == "beads" then "dummy-beads-${lowerName}"
    else if source == "config" then "dummy-config-${lowerName}"
    else "dummy-${lowerName}";

  # Generate dummy values for all defined variables
  allDummyVars = builtins.mapAttrs makeDummy variableDefs;

  # Filter to only include variables this template needs
  templateVars = lib.filterAttrs (k: v: builtins.elem k template.variables) allDummyVars;

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

# Skip if no flake root available
if [ -z "$FLAKE_ROOT" ]; then
  echo "  ⚠ Variable check skipped (no flake root)"
else

# Create a temporary Nix file for the variable check expression
# This avoids shell escaping issues with the regex pattern
VAR_CHECK_NIX=$(mktemp)
# shellcheck disable=SC2064
trap "rm -f $VAR_CHECK_NIX" EXIT

cat > "$VAR_CHECK_NIX" << NIXEOF
let
  flake = builtins.getFlake (toString $FLAKE_ROOT);
  lib = flake.inputs.nixpkgs.lib;
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
  for template in plan-new plan-update todo-new todo-update step; do
    undeclared=$(echo "$var_check" | jq -r ".\"$template\".undeclared | length" 2>/dev/null)
    if [ "$undeclared" = "0" ]; then
      echo "  ✓ $template (all variables declared)"
    else
      undeclared_list=$(echo "$var_check" | jq -r ".\"$template\".undeclared | join(\", \")" 2>/dev/null)
      echo "  ✗ $template (undeclared variables: $undeclared_list)"
      ERRORS+=("Template $template uses undeclared variables: $undeclared_list")
    fi
  done
else
  echo "  ⚠ Variable check skipped (evaluation failed)"
fi

fi # End of FLAKE_ROOT check

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
