#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  start) exec ralph-start "$@" ;;
  plan)  exec ralph-plan "$@" ;;
  logs)  exec ralph-logs "$@" ;;
  tune)  exec ralph-tune "$@" ;;
  ready) exec ralph-ready "$@" ;;
  step)  exec ralph-step "$@" ;;
  loop)  exec ralph-loop "$@" ;;
  status) exec ralph-status "$@" ;;
  # Backwards compatibility: init -> start
  init)
    echo "Note: 'ralph init' is now 'ralph start'"
    exec ralph-start "$@"
    ;;
  help|--help|-h)
    echo "Usage: ralph <command> [args]"
    echo ""
    echo "Spec-Driven Workflow Commands:"
    echo "  start [label]   Start a new feature (clears state, sets label)"
    echo "  plan            Run specification interview"
    echo "  ready           Convert spec to beads issues"
    echo "  step [feature]  Work one issue (fresh context), then exit"
    echo "  loop [feature]  Loop through all steps until done"
    echo "  status          Show current workflow state"
    echo ""
    echo "Utility Commands:"
    echo "  logs [N]          View recent work logs (default 5)"
    echo "  tune <phase>      Edit prompt template (plan|step)"
    echo ""
    echo "Workflow:"
    echo "  1. ralph start my-feature  # Start new feature"
    echo "  2. ralph plan              # Interview to create spec"
    echo "  3. ralph ready             # Convert spec to beads"
    echo "  4. ralph loop              # Work through all tasks"
    echo "  5. ralph status            # Check progress"
    echo ""
    echo "Multi-Feature Support:"
    echo "  ralph step feature-a       # Work on specific feature"
    echo "  ralph loop feature-b       # Loop through specific feature"
    echo ""
    echo "Environment:"
    echo "  RALPH_DIR  Working directory (default: .claude/ralph)"
    ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Run 'ralph help' for usage"
    exit 1
    ;;
esac
