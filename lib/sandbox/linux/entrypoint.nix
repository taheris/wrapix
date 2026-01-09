{ pkgs }:

pkgs.writeShellScriptBin "wrapix-entrypoint" ''
  cd /workspace

  exec claude \
    --dangerously-skip-permissions \
    --append-system-prompt "$(cat /etc/wrapix-prompt)"
''
