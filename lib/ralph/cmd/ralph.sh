#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  plan)  exec ralph-plan "$@" ;;
  logs)  exec ralph-logs "$@" ;;
  ready) exec ralph-ready "$@" ;;
  step)  exec ralph-step "$@" ;;
  loop)  exec ralph-loop "$@" ;;
  status) exec ralph-status "$@" ;;
  diff)  exec ralph-diff "$@" ;;
  edit)
    # Get current label and hidden flag from current.json
    CURRENT_FILE="$RALPH_DIR/state/current.json"
    if [ ! -f "$CURRENT_FILE" ]; then
      echo "No active feature. Run 'ralph plan <label>' first."
      exit 1
    fi
    LABEL=$(jq -r '.label // empty' "$CURRENT_FILE")
    SPEC_HIDDEN=$(jq -r '.hidden // false' "$CURRENT_FILE")
    if [ -z "$LABEL" ]; then
      echo "No label in current.json. Run 'ralph plan <label>' first."
      exit 1
    fi

    if [ "$SPEC_HIDDEN" = "true" ]; then
      SPEC_FILE="$RALPH_DIR/state/$LABEL.md"
    else
      SPEC_FILE="specs/$LABEL.md"
    fi

    if [ ! -f "$SPEC_FILE" ]; then
      echo "Spec file not found: $SPEC_FILE"
      echo "Run 'ralph plan $LABEL' to create it."
      exit 1
    fi
    exec "${EDITOR:-vi}" "$SPEC_FILE"
    ;;
  tune)
    PROMPT_FILE="$RALPH_DIR/step.md"
    if [ ! -f "$PROMPT_FILE" ]; then
      echo "Prompt file not found: $PROMPT_FILE"
      echo "Run 'ralph plan <label>' first."
      exit 1
    fi
    exec "${EDITOR:-vi}" "$PROMPT_FILE"
    ;;
  # Backwards compatibility: start -> plan, init -> plan
  start|init)
    echo "Note: 'ralph $COMMAND' is now 'ralph plan <label>'"
    exec ralph-plan "$@"
    ;;
  help|--help|-h)
    echo "Usage: ralph <command> [args]"
    echo ""
    echo "Spec-Driven Workflow Commands:"
    echo "  plan <label>    Start/continue a feature (sets label, runs spec interview)"
    echo "  ready           Convert spec to beads issues"
    echo "  step [feature]  Work one issue (fresh context), then exit"
    echo "  loop [feature]  Loop through all steps until done"
    echo "  status          Show current workflow state"
    echo ""
    echo "Template Commands:"
    echo "  diff [name]     Show local template changes vs packaged"
    echo "  tune            Edit step prompt template (step.md)"
    echo ""
    echo "Utility Commands:"
    echo "  logs [N]        View recent work logs (default 5)"
    echo "  edit            Edit current spec file"
    echo ""
    echo "Workflow:"
    echo "  1. ralph plan my-feature   # Start feature and run spec interview"
    echo "  2. ralph edit              # Adjust spec if needed"
    echo "  3. ralph ready             # Convert spec to beads"
    echo "  4. ralph step              # Work one task to test prompts"
    echo "  5. ralph tune              # Adjust step prompt if needed"
    echo "  6. ralph loop              # Work through remaining tasks"
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
