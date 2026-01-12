# Container-side notification client
#
# Sends notification requests to the host daemon via Unix socket.
# Silently succeeds if daemon is not running (socket doesn't exist).
#
# Usage: wrapix-notify "Title" "Message" ["Sound"]
{ pkgs }:

pkgs.writeShellScriptBin "wrapix-notify" ''
  SOCKET="/run/wrapix/notify.sock"
  title="''${1:-Claude Code}"
  message="''${2:-}"
  sound="''${3:-}"

  if [ ! -S "$SOCKET" ]; then
    exit 0  # Silent success if daemon not running
  fi

  printf '{"title":"%s","message":"%s","sound":"%s"}\n' \
    "$title" "$message" "$sound" | \
    ${pkgs.netcat}/bin/nc -U -N "$SOCKET" 2>/dev/null || true
''
