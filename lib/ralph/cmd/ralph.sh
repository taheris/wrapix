#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  start) exec ralph-start "$@" ;;
  plan)  exec ralph-plan "$@" ;;
  logs)  exec ralph-logs "$@" ;;
  ready) exec ralph-ready "$@" ;;
  step)  exec ralph-step "$@" ;;
  loop)  exec ralph-loop "$@" ;;
  status) exec ralph-status "$@" ;;
  edit)
    PROMPT_FILE="$RALPH_DIR/plan.md"
    if [ ! -f "$PROMPT_FILE" ]; then
      echo "Prompt file not found: $PROMPT_FILE"
      echo "Run 'ralph start <label>' first."
      exit 1
    fi
    exec "${EDITOR:-vi}" "$PROMPT_FILE"
    ;;
  tune)
    PROMPT_FILE="$RALPH_DIR/step.md"
    if [ ! -f "$PROMPT_FILE" ]; then
      echo "Prompt file not found: $PROMPT_FILE"
      echo "Run 'ralph start <label>' first."
      exit 1
    fi
    exec "${EDITOR:-vi}" "$PROMPT_FILE"
    ;;
  # Backwards compatibility: init -> start
  init)
    echo "Note: 'ralph init' is now 'ralph start'"
    exec ralph-start "$@"
    ;;
  help|--help|-h)
    echo "Usage: ralph <command> [args]"
    echo ""
    echo "Spec-Driven Workflow Commands:"
    echo "  start <label>   Start a new feature (sets label, substitutes templates)"
    echo "  plan            Run specification interview"
    echo "  ready           Convert spec to beads issues"
    echo "  step [feature]  Work one issue (fresh context), then exit"
    echo "  loop [feature]  Loop through all steps until done"
    echo "  status          Show current workflow state"
    echo ""
    echo "Utility Commands:"
    echo "  logs [N]        View recent work logs (default 5)"
    echo "  edit            Edit plan prompt template (plan.md)"
    echo "  tune            Edit step prompt template (step.md)"
    echo ""
    echo "Workflow:"
    echo "  1. ralph start my-feature  # Start new feature"
    echo "  2. ralph plan              # Interview to create spec"
    echo "  3. ralph edit              # Adjust plan prompt if needed"
    echo "  4. ralph ready             # Convert spec to beads"
    echo "  5. ralph step              # Work one task to test prompts"
    echo "  6. ralph tune              # Adjust step prompt if needed"
    echo "  7. ralph loop              # Work through remaining tasks"
    echo ""
    echo "Multi-Feature Support:"
    echo "  ralph step feature-a       # Work on specific feature"
    echo "  ralph loop feature-b       # Loop through specific feature"
    echo ""
    echo "Environment:"
    echo "  RALPH_DIR    Working directory (default: .claude/ralph)"
    echo "  RALPH_DEBUG  Enable debug output (set to 1)"
    ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Run 'ralph help' for usage"
    exit 1
    ;;
esac
