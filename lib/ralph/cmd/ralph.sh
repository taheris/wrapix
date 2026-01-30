#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.claude/ralph}"
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  check)  exec ralph-check  "$@" ;;
  diff)   exec ralph-diff   "$@" ;;
  logs)   exec ralph-logs   "$@" ;;
  loop)   exec ralph-loop   "$@" ;;
  plan)   exec ralph-plan   "$@" ;;
  ready)  exec ralph-ready  "$@" ;;
  status) exec ralph-status "$@" ;;
  step)   exec ralph-step   "$@" ;;
  sync)   exec ralph-sync   "$@" ;;
  tune)   exec ralph-tune   "$@" ;;

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
    echo "  check           Validate all templates (syntax, partials, rendering)"
    echo "  diff [name]     Show local template changes vs packaged"
    echo "  sync            Update local templates from packaged (backs up customizations)"
    echo "  tune            AI-assisted template editing (interactive or via diff)"
    echo ""
    echo "Utility Commands:"
    echo "  logs [N]        View recent work logs (default 5)"
    echo "  edit            Edit current spec file"
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
