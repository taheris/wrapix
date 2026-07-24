{ pkgs }:

pkgs.writeShellApplication {
  name = "wrix-prek";
  runtimeInputs = [ pkgs.prek ];
  text = ''
    set -euo pipefail
    if [[ "''${1:-}" = "--print-bin-dir" ]]; then
      printf '%s\n' "${pkgs.prek}/bin"
      exit 0
    fi
    exec prek "$@"
  '';
}
