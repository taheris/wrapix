#!/usr/bin/env bash
set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.wrapix/ralph}"
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  check)  exec ralph-check  "$@" ;;
  logs)   exec ralph-logs   "$@" ;;
  plan)   exec ralph-plan   "$@" ;;
  run)    exec ralph-run    "$@" ;;
  spec)   exec ralph-spec   "$@" ;;
  status) exec ralph-status "$@" ;;
  sync)   exec ralph-sync   "$@" ;;
  todo)   exec ralph-todo   "$@" ;;
  tune)   exec ralph-tune   "$@" ;;
  use)    exec ralph-use    "$@" ;;

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
    echo "  plan            Spec interview and creation:"
    echo "    -n <label>      New spec in specs/"
    echo "    -h <label>      New hidden spec in state/"
    echo "    -u <spec>       Update existing spec (-uh for hidden)"
    echo "  todo            Convert spec to beads issues"
    echo "  run [feature]   Execute work items for a feature"
    echo "    --once/-1       Execute single issue then exit"
    echo "    --profile=X     Override container profile (rust, python, base)"
    echo "  spec            Query spec annotations"
    echo "    --verbose       Show per-criterion detail"
    echo "    --verify        Run [verify] shell tests"
    echo "    --judge         Run [judge] LLM evaluations"
    echo "    --all           Run both verify and judge"
    echo "  status          Show current workflow state"
    echo "  use <name>      Switch active workflow"
    echo ""
    echo "Template Commands:"
    echo "  check           Validate all templates (syntax, partials, rendering)"
    echo "  sync            Update local templates from packaged (backs up customizations)"
    echo "    --diff [name]   Show local template changes vs packaged"
    echo "  tune            AI-assisted template editing (interactive or via diff)"
    echo ""
    echo "Utility Commands:"
    echo "  logs [N]        View recent work logs (default 5)"
    echo "  edit            Edit current spec file"
    echo ""
    echo "Environment:"
    echo "  RALPH_DIR    Working directory (default: .wrapix/ralph)"
    echo "  RALPH_DEBUG  Enable debug output (set to 1)"
    ;;

  *)
    echo "Unknown command: $COMMAND"
    echo "Run 'ralph help' for usage"
    exit 1
    ;;
esac
