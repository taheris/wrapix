#!/usr/bin/env bash
set -euo pipefail

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  init)  exec ralph-init "$@" ;;
  plan)  exec ralph-plan "$@" ;;
  logs)  exec ralph-logs "$@" ;;
  tune)  exec ralph-tune "$@" ;;
  ready) exec ralph-ready "$@" ;;
  step)  exec ralph-step "$@" ;;
  loop)  exec ralph-loop "$@" ;;
  help|--help|-h)
    echo "Usage: ralph <command> [args]"
    echo ""
    echo "Commands:"
    echo "  init              Initialize ralph directory"
    echo "  plan              Run the planning loop (fresh context per iteration)"
    echo "  logs <phase> [N]  View recent logs (plan|step, default 5)"
    echo "  tune <phase>      Edit prompt template (plan|step)"
    echo "  ready             Convert plan to beads issues"
    echo "  step              Work one issue (fresh context), then exit"
    echo "  loop              Loop through all steps until done"
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
