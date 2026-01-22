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
  handlerScript =
    if isDarwin then
      ''
        while read -r line; do
          title=$(printf '%s\n' "$line" | jq -r '.title // "Claude Code"')
          msg=$(printf '%s\n' "$line" | jq -r '.message // ""')
          sound=$(printf '%s\n' "$line" | jq -r '.sound // ""')
          args=(-title "$title" -message "$msg")
          [ -n "$sound" ] && args+=(-sound "$sound")
          terminal-notifier "''${args[@]}"
        done
      ''
    else
      ''
        while read -r line; do
          title=$(printf '%s\n' "$line" | jq -r '.title // "Claude Code"')
          msg=$(printf '%s\n' "$line" | jq -r '.message // ""')
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
