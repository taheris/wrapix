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

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"

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

# Check spec file exists
if [ ! -f "$SPEC_PATH" ]; then
  echo "Error: Spec file not found: $SPEC_PATH"
  echo "Run 'ralph plan' first to create the specification."
  exit 1
fi

PROMPT_TEMPLATE="$RALPH_DIR/template/ready.md"
if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "Error: Ready prompt template not found: $PROMPT_TEMPLATE"
  echo "Make sure ready.md exists in your ralph directory."
  exit 1
fi

# Validate template has placeholders, reset from source if corrupted
validate_template "$PROMPT_TEMPLATE" "$TEMPLATE/ready.md" "ready.md"

mkdir -p "$RALPH_DIR/logs"

# Pin context from specs/README.md
PINNED_CONTEXT=""
if [ -f "$SPECS_README" ]; then
  PINNED_CONTEXT=$(cat "$SPECS_README")
fi

# Extract title from spec file (first heading)
SPEC_TITLE=$(grep -m 1 '^#' "$SPEC_PATH" | sed 's/^#* *//' || echo "$SPEC_NAME")

# Build mode-specific content for the template
MODE="new"
MOLECULE_CONTEXT=""
WORKFLOW_INSTRUCTIONS=""
OUTPUT_FORMAT=""

if [ "$UPDATE_MODE" = "true" ]; then
  MODE="update"

  # Get existing molecule ID from current.json (may be empty)
  MOLECULE_ID=$(jq -r '.molecule // empty' "$CURRENT_FILE")

  # Query existing beads with this label (regardless of whether molecule exists)
  EXISTING_BEADS=$(bd list --label "spec-$LABEL" --format json 2>/dev/null || echo "[]")
  EXISTING_COUNT=$(echo "$EXISTING_BEADS" | jq 'length')

  if [ -n "$MOLECULE_ID" ]; then
    # Molecule exists - bond new tasks to it
    MOLECULE_CONTEXT="Molecule ID: $MOLECULE_ID

## Existing Tasks

This is an UPDATE to an existing molecule. The following tasks already exist:

\`\`\`json
$EXISTING_BEADS
\`\`\`"

    WORKFLOW_INSTRUCTIONS="1. **Read the spec file** at {{SPEC_PATH}} thoroughly
2. **Identify NEW requirements** not covered by existing tasks
3. **Create new tasks as children of the molecule** using --parent flag
4. **Add dependencies** where new tasks depend on existing or other new tasks
{{README_INSTRUCTIONS}}

**IMPORTANT**: Do NOT recreate the epic or any existing tasks. Only create NEW tasks for requirements that are not already covered. If no new tasks are needed, just output RALPH_COMPLETE."

    OUTPUT_FORMAT="## Output Format

For each NEW implementation task, create it as a child of the molecule:
\`\`\`bash
# Create the new task as a child of the molecule
TASK_ID=\$(bd create --title=\"Task title\" --description=\"Description with context\" --type=task --priority=N --labels=\"spec-{{LABEL}}\" --parent=\"$MOLECULE_ID\" --silent)
\`\`\`

Add dependencies between tasks:
\`\`\`bash
bd dep add <dependent-task> <depends-on-task>
\`\`\`"
  else
    # Update mode but no molecule - create one while checking for existing tasks
    MOLECULE_CONTEXT="## Existing Tasks

This is an UPDATE to an existing spec but no molecule exists yet. The following tasks may already exist:

\`\`\`json
$EXISTING_BEADS
\`\`\`"

    WORKFLOW_INSTRUCTIONS="1. **Read the spec file** at {{SPEC_PATH}} thoroughly
2. **Create a parent epic bead** as the molecule root
3. **Capture the epic ID** for use as the molecule root
4. **Store the molecule ID** in current.json
5. **Identify NEW requirements** not covered by existing tasks (if any)
6. **Create new tasks** and bond them to the molecule
7. **Add dependencies** where tasks depend on each other
{{README_INSTRUCTIONS}}

**IMPORTANT**: Do NOT recreate any existing tasks. Only create NEW tasks for requirements that are not already covered."

    OUTPUT_FORMAT="## Output Format

First, create the epic bead and capture its ID (this becomes the molecule root):
\`\`\`bash
MOLECULE_ID=\$(bd create --title=\"{{SPEC_TITLE}}\" --type=epic --priority={{PRIORITY}} --labels=\"spec-{{LABEL}}\" --silent)
echo \"Created molecule root: \$MOLECULE_ID\"
\`\`\`

**CRITICAL**: Store the molecule ID in current.json:
\`\`\`bash
jq --arg mol \"\$MOLECULE_ID\" '.molecule = \$mol' {{CURRENT_FILE}} > {{CURRENT_FILE}}.tmp && mv {{CURRENT_FILE}}.tmp {{CURRENT_FILE}}
\`\`\`

Then, for each NEW implementation task, create it as a child of the molecule:
\`\`\`bash
# Create the task as a child of the molecule (this enables molecule progress tracking)
TASK_ID=\$(bd create --title=\"Task title\" --description=\"Description with context\" --type=task --priority=N --labels=\"spec-{{LABEL}}\" --parent=\"\$MOLECULE_ID\" --silent)
\`\`\`

Add dependencies between tasks:
\`\`\`bash
bd dep add <dependent-task> <depends-on-task>
\`\`\`"
  fi
else
  # New spec mode - create molecule from scratch
  MOLECULE_CONTEXT=""

  WORKFLOW_INSTRUCTIONS="1. **Read the spec file** at {{SPEC_PATH}} thoroughly
2. **Create a parent epic bead** as the molecule root
3. **Capture the epic ID** for use as the molecule root
4. **Store the molecule ID** in current.json
5. **Create tasks as children of the epic** using --parent flag
6. **Add dependencies** where tasks depend on each other
{{README_INSTRUCTIONS}}"

  OUTPUT_FORMAT="## Output Format

First, create the epic bead and capture its ID (this becomes the molecule root):
\`\`\`bash
MOLECULE_ID=\$(bd create --title=\"{{SPEC_TITLE}}\" --type=epic --priority={{PRIORITY}} --labels=\"spec-{{LABEL}}\" --silent)
echo \"Created molecule root: \$MOLECULE_ID\"
\`\`\`

**CRITICAL**: Store the molecule ID in current.json:
\`\`\`bash
jq --arg mol \"\$MOLECULE_ID\" '.molecule = \$mol' {{CURRENT_FILE}} > {{CURRENT_FILE}}.tmp && mv {{CURRENT_FILE}}.tmp {{CURRENT_FILE}}
\`\`\`

Then, for each implementation task, create it as a child of the molecule:
\`\`\`bash
# Create the task as a child of the molecule (this enables molecule progress tracking)
TASK_ID=\$(bd create --title=\"Task title\" --description=\"Description with context\" --type=task --priority=N --labels=\"spec-{{LABEL}}\" --parent=\"\$MOLECULE_ID\" --silent)
\`\`\`

Add dependencies between tasks:
\`\`\`bash
bd dep add <dependent-task> <depends-on-task>
\`\`\`"
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

# Substitute simple placeholders at runtime
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{LABEL\}\}/$LABEL}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{SPEC_PATH\}\}/$SPEC_PATH}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{PRIORITY\}\}/$DEFAULT_PRIORITY}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{SPEC_TITLE\}\}/$SPEC_TITLE}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{MODE\}\}/$MODE}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{CURRENT_FILE\}\}/$CURRENT_FILE}"
PROMPT_CONTENT="${PROMPT_CONTENT//\{\{EXIT_SIGNALS\}\}/}"

# Multi-line substitutions using awk (handles newlines in replacement text)
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v replacement="$README_INSTRUCTIONS" '{gsub(/\{\{README_INSTRUCTIONS\}\}/, replacement); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v replacement="$README_UPDATE_SECTION" '{gsub(/\{\{README_UPDATE_SECTION\}\}/, replacement); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$PINNED_CONTEXT" '{gsub(/\{\{PINNED_CONTEXT\}\}/, ctx); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$MOLECULE_CONTEXT" '{gsub(/\{\{MOLECULE_CONTEXT\}\}/, ctx); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$WORKFLOW_INSTRUCTIONS" '{gsub(/\{\{WORKFLOW_INSTRUCTIONS\}\}/, ctx); print}')
PROMPT_CONTENT=$(echo "$PROMPT_CONTENT" | awk -v ctx="$OUTPUT_FORMAT" '{gsub(/\{\{OUTPUT_FORMAT\}\}/, ctx); print}')

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

  # Strip Implementation Notes section from spec if present
  FINAL_SPEC_PATH="$SPECS_DIR/$LABEL.md"
  SPEC_CONTENT=$(cat "$SPEC_PATH")
  FINAL_CONTENT=$(strip_implementation_notes "$SPEC_CONTENT")

  if [ "$SPEC_CONTENT" != "$FINAL_CONTENT" ]; then
    echo ""
    echo "Stripping Implementation Notes from $FINAL_SPEC_PATH..."
    echo "$FINAL_CONTENT" > "$FINAL_SPEC_PATH"
  fi

  # Commit the spec file
  if [ -f "$FINAL_SPEC_PATH" ]; then
    echo ""
    echo "Committing spec..."
    git add "$FINAL_SPEC_PATH" "$SPECS_README" 2>/dev/null || true
    if git diff --cached --quiet 2>/dev/null; then
      echo "  (no changes to commit)"
    else
      git commit -m "Add $LABEL specification" >/dev/null 2>&1 && echo "  Committed: $FINAL_SPEC_PATH" || echo "  (commit failed or nothing to commit)"
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
