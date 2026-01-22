# Container-side notification client
#
# Sends notification requests to the host daemon via Unix socket.
# Silently succeeds if daemon is not running (socket doesn't exist).
#
# Usage: wrapix-notify "Title" "Message" ["Sound"]
{ pkgs }:

pkgs.writeShellScriptBin "wrapix-notify" ''
  SOCKET="/run/wrapix/notify.sock"
  VERBOSE="''${WRAPIX_NOTIFY_VERBOSE:-0}"
  title="''${1:-Claude Code}"
  message="''${2:-}"
  sound="''${3:-}"

  if [ ! -S "$SOCKET" ]; then
    [ "$VERBOSE" = "1" ] && echo "wrapix-notify: socket not found at $SOCKET" >&2
    exit 0  # Silent success if daemon not running
  fi

  # Use jq for safe JSON construction to prevent injection via quotes/backslashes
  ${pkgs.jq}/bin/jq -n --arg t "$title" --arg m "$message" --arg s "$sound" \
    '{title: $t, message: $m, sound: $s}' | \
    ${pkgs.netcat}/bin/nc -U -N "$SOCKET" 2>/dev/null || true
  [ "$VERBOSE" = "1" ] && echo "wrapix-notify: sent to $SOCKET" >&2
  exit 0
''
