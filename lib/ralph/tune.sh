#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
PHASE="${1:-}"

case "$PHASE" in
  plan) PROMPT_FILE="$RALPH_DIR/prompts/plan.md" ;;
  step) PROMPT_FILE="$RALPH_DIR/prompts/step.md" ;;
  "")
    echo "Usage: ralph tune <plan|step>"
    echo ""
    echo "  plan  Edit prompts/plan.md"
    echo "  step  Edit prompts/step.md"
    exit 0
    ;;
  *)
    echo "Unknown phase: $PHASE"
    echo "Usage: ralph tune <plan|step>"
    exit 1
    ;;
esac

if [ ! -f "$PROMPT_FILE" ]; then
  echo "Prompt file not found: $PROMPT_FILE"
  exit 1
fi

exec "${EDITOR:-vi}" "$PROMPT_FILE"
