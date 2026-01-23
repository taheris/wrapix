# Host-side notification daemon
#
# Listens for notification requests and triggers native desktop notifications.
#
# On Linux: Listens on Unix socket (mounted into containers)
# On Darwin: Listens on TCP port 5959 (VirtioFS can't pass Unix sockets)
#            Also listens on Unix socket for local testing
#
# Usage: nix run .#wrapix-notifyd
{ pkgs }:

let
  inherit (pkgs.stdenv) isDarwin;
  tcpPort = "5959";

  # Inline handler script - socat SYSTEM can't access exported bash functions
  # Includes focus check to suppress notifications when terminal is focused
  handlerScript =
    if isDarwin then
      ''
        WRAPIX_SESSION_DIR="''${XDG_DATA_HOME:-$HOME/.local/share}/wrapix/sessions"
        VERBOSE="''${WRAPIX_NOTIFY_VERBOSE:-0}"

        # Focus check function (Darwin) - uses app name (no window ID available via osascript)
        check_terminal_focused() {
          local session_id="$1"
          local safe_id="''${session_id//[:\.]/-}"
          local session_file="$WRAPIX_SESSION_DIR/$safe_id.json"

          if [ ! -f "$session_file" ]; then
            [ "$VERBOSE" = "1" ] && echo "notifyd: session file not found: $session_file" >&2
            return 1  # No session = show notification
          fi

          local session_app
          session_app=$(jq -r '.terminal_app // ""' "$session_file")
          if [ -z "$session_app" ]; then
            [ "$VERBOSE" = "1" ] && echo "notifyd: no terminal_app in session file" >&2
            return 1
          fi

          local focused_app
          if ! focused_app=$(osascript -e 'tell application "System Events" to name of first process whose frontmost is true' 2>/dev/null); then
            [ "$VERBOSE" = "1" ] && echo "notifyd: failed to query focused app via osascript" >&2
            return 1
          fi

          [ "$VERBOSE" = "1" ] && echo "notifyd: session=$session_app focused=$focused_app" >&2
          [ "$focused_app" = "$session_app" ]
        }

        while read -r line; do
          title=$(printf '%s\n' "$line" | jq -r '.title // "Claude Code"')
          msg=$(printf '%s\n' "$line" | jq -r '.message // ""')
          sound=$(printf '%s\n' "$line" | jq -r '.sound // ""')
          session_id=$(printf '%s\n' "$line" | jq -r '.session_id // ""')

          # Check focus - skip notification if terminal is focused (unless WRAPIX_NOTIFY_ALWAYS=1)
          if [ "''${WRAPIX_NOTIFY_ALWAYS:-}" != "1" ] && [ -n "$session_id" ]; then
            if check_terminal_focused "$session_id"; then
              [ "$VERBOSE" = "1" ] && echo "notifyd: suppressed (terminal focused)" >&2
              continue
            fi
          fi

          args=(-title "$title" -message "$msg")
          [ -n "$sound" ] && args+=(-sound "$sound")
          terminal-notifier "''${args[@]}"
        done
      ''
    else
      ''
        WRAPIX_SESSION_DIR="''${XDG_RUNTIME_DIR:-$HOME/.local/share}/wrapix/sessions"
        VERBOSE="''${WRAPIX_NOTIFY_VERBOSE:-0}"

        # Focus check function (Linux/niri) - uses window ID for exact matching
        check_terminal_focused() {
          local session_id="$1"
          local safe_id="''${session_id//[:\.]/-}"
          local session_file="$WRAPIX_SESSION_DIR/$safe_id.json"

          if [ ! -f "$session_file" ]; then
            [ "$VERBOSE" = "1" ] && echo "notifyd: session file not found: $session_file" >&2
            return 1  # No session = show notification
          fi

          local session_window_id
          session_window_id=$(jq -r '.window_id // ""' "$session_file")
          if [ -z "$session_window_id" ]; then
            [ "$VERBOSE" = "1" ] && echo "notifyd: no window_id in session file" >&2
            return 1
          fi

          local focused_window_id
          if ! focused_window_id=$(niri msg -j focused-window 2>/dev/null | jq -r '.id // ""'); then
            [ "$VERBOSE" = "1" ] && echo "notifyd: failed to query niri focused-window" >&2
            return 1
          fi

          [ "$VERBOSE" = "1" ] && echo "notifyd: session=$session_window_id focused=$focused_window_id" >&2
          [ "$focused_window_id" = "$session_window_id" ]
        }

        while read -r line; do
          title=$(printf '%s\n' "$line" | jq -r '.title // "Claude Code"')
          msg=$(printf '%s\n' "$line" | jq -r '.message // ""')
          session_id=$(printf '%s\n' "$line" | jq -r '.session_id // ""')

          # Check focus - skip notification if terminal is focused (unless WRAPIX_NOTIFY_ALWAYS=1)
          if [ "''${WRAPIX_NOTIFY_ALWAYS:-}" != "1" ] && [ -n "$session_id" ]; then
            if check_terminal_focused "$session_id"; then
              [ "$VERBOSE" = "1" ] && echo "notifyd: suppressed (terminal focused)" >&2
              continue
            fi
          fi

          notify-send "$title" "$msg"
        done
      '';

in
pkgs.writeShellApplication {
  name = "wrapix-notifyd";
  runtimeInputs =
    with pkgs;
    [
      coreutils
      jq
      socat
    ]
    ++ (if isDarwin then [ terminal-notifier ] else [ libnotify ]);

  text = ''
    SOCKET="''${XDG_RUNTIME_DIR:-$HOME/.local/share}/wrapix/notify.sock"
    mkdir -p "$(dirname "$SOCKET")"
    rm -f "$SOCKET"
    trap 'rm -f "$SOCKET"' EXIT

    # Write handler script to temp file (socat SYSTEM can't use exported functions)
    HANDLER_SCRIPT=$(mktemp)
    trap 'rm -f "$SOCKET" "$HANDLER_SCRIPT"' EXIT
    cat > "$HANDLER_SCRIPT" << 'HANDLER_EOF'
    ${handlerScript}
    HANDLER_EOF
    chmod +x "$HANDLER_SCRIPT"

    ${
      if isDarwin then
        ''
          # Darwin: listen on TCP (for containers) and Unix socket (for local testing)
          # Containers reach host via vmnet gateway (typically 192.168.64.1)
          echo "wrapix-notifyd: listening on TCP port ${tcpPort} and $SOCKET"
          socat UNIX-LISTEN:"$SOCKET",fork EXEC:"bash $HANDLER_SCRIPT" &
          SOCKET_PID=$!
          trap 'rm -f "$SOCKET" "$HANDLER_SCRIPT"; kill $SOCKET_PID 2>/dev/null' EXIT
          # Bind to vmnet interface only (not all interfaces) for security
          # Containers see host as 192.168.64.1; binding there limits exposure
          socat TCP-LISTEN:${tcpPort},bind=192.168.64.1,fork,reuseaddr EXEC:"bash $HANDLER_SCRIPT"
        ''
      else
        ''
          # Linux: listen on Unix socket only (mounted into containers)
          echo "wrapix-notifyd: listening on $SOCKET"
          socat UNIX-LISTEN:"$SOCKET",fork EXEC:"bash $HANDLER_SCRIPT"
        ''
    }
  '';
}
