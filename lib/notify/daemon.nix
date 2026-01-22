# Host-side notification daemon
#
# Listens on a Unix socket and triggers native desktop notifications.
# The socket is mounted into containers, allowing Claude Code hooks
# to send notifications from inside the sandbox.
#
# Usage: nix run .#wrapix-notifyd
{ pkgs }:

let
  inherit (pkgs.stdenv) isDarwin;

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

    notify() {
      local title="$1" msg="$2" sound="''${3:-}"
      ${
        if isDarwin then
          ''
            args=(-title "$title" -message "$msg")
            [ -n "$sound" ] && args+=(-sound "$sound")
            terminal-notifier "''${args[@]}"
          ''
        else
          ''
            notify-send "$title" "$msg"
          ''
      }
    }

    # Handler script for each connection - receives JSON on stdin
    handler() {
      while read -r line; do
        title=$(printf '%s\n' "$line" | jq -r '.title // "Claude Code"')
        msg=$(printf '%s\n' "$line" | jq -r '.message // ""')
        sound=$(printf '%s\n' "$line" | jq -r '.sound // ""')
        notify "$title" "$msg" "$sound"
      done
    }
    export -f handler notify

    echo "wrapix-notifyd: listening on $SOCKET"
    socat UNIX-LISTEN:"$SOCKET",fork SYSTEM:'bash -c handler'
  '';
}
