#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
CONFIG_FILE="$RALPH_DIR/config.nix"
PLAN="$RALPH_DIR/state/plan.md"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: No ralph config found at $CONFIG_FILE"
  exit 1
fi

if [ ! -f "$PLAN" ]; then
  echo "Error: No plan found at $PLAN"
  echo "Run 'ralph plan' first to generate a plan."
  exit 1
fi

if [ ! -s "$PLAN" ]; then
  echo "Error: Plan file is empty at $PLAN"
  exit 1
fi

# Load config as JSON once
CONFIG=$(nix eval --json --file "$CONFIG_FILE")
LABEL_SUFFIX=$(echo "$CONFIG" | jq -r '.beads.label // empty')
DEFAULT_PRIORITY=$(echo "$CONFIG" | jq -r '.beads.priority // 2')
DEFAULT_TYPE=$(echo "$CONFIG" | jq -r '.beads."default-type" // "task"')

# Generate random 6-char suffix if not set in config
if [ -z "$LABEL_SUFFIX" ]; then
  LABEL_SUFFIX=$(head -c 6 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 6)
fi
LABEL="rl-$LABEL_SUFFIX"

echo "Converting plan to beads issues..."
echo "  Label: $LABEL"
echo "  Default priority: $DEFAULT_PRIORITY"
echo "  Default type: $DEFAULT_TYPE"
echo ""

# Save label to state file for step phase to use
echo "$LABEL" > "$RALPH_DIR/state/label"

# Parse YAML frontmatter documents (separated by ---)
# Each document should have frontmatter followed by body
ISSUE_COUNT=0

# Use awk to extract frontmatter blocks
awk '
BEGIN { in_doc = 0; fm = ""; body = "" }
/^---[[:space:]]*$/ {
  if (in_doc && fm != "") {
    # End of document, output it
    gsub(/\n$/, "", body)
    print fm "|||BODY|||" body
    fm = ""; body = ""
  }
  in_doc = !in_doc
  next
}
in_doc && /^[a-z]+:/ { fm = fm $0 "\n"; next }
!in_doc && NF { body = body $0 "\n" }
END {
  if (fm != "") {
    gsub(/\n$/, "", body)
    print fm "|||BODY|||" body
  }
}
' "$PLAN" | while IFS= read -r doc; do
  # Parse frontmatter
  fm="${doc%%|||BODY|||*}"
  body="${doc#*|||BODY|||}"

  # Extract fields from frontmatter
  type=$(echo "$fm" | grep -E "^type:" | sed 's/^type:[[:space:]]*//' | tr -d '\n' || echo "$DEFAULT_TYPE")
  title=$(echo "$fm" | grep -E "^title:" | sed 's/^title:[[:space:]]*//' | tr -d '\n')
  priority=$(echo "$fm" | grep -E "^priority:" | sed 's/^priority:[[:space:]]*//' | tr -d '\n' || echo "$DEFAULT_PRIORITY")

  # Use defaults if empty
  [ -z "$type" ] && type="$DEFAULT_TYPE"
  [ -z "$priority" ] && priority="$DEFAULT_PRIORITY"

  # Skip if no title
  [ -z "$title" ] && continue

  echo "Creating $type: $title (P$priority)"

  # Create the bead with description if body exists
  if [ -n "$body" ]; then
    bd create --title="$title" --description="$body" \
      --type="$type" --priority="$priority" --labels="$LABEL"
  else
    bd create --title="$title" \
      --type="$type" --priority="$priority" --labels="$LABEL"
  fi

  ((ISSUE_COUNT++)) || true
done

echo ""
echo "Beads created with label: $LABEL"
echo ""
echo "To work through issues:"
echo "  ralph step      # Work one issue at a time"
echo "  ralph loop      # Work all issues automatically"
echo ""
echo "To list created issues:"
echo "  bd list --labels=$LABEL"
