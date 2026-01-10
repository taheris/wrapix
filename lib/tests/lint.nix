# Lint checks - verify code formatting and style
{
  pkgs,
  src,
}:

{
  # Verify all Nix files are formatted with nixfmt
  nixfmt =
    pkgs.runCommand "check-nixfmt"
      {
        nativeBuildInputs = [ pkgs.nixfmt-rfc-style ];
      }
      ''
        cd ${src}
        find . -name '*.nix' -exec nixfmt --check {} +
        touch $out
      '';

  # Lint shell scripts with shellcheck
  shellcheck =
    pkgs.runCommand "check-shellcheck"
      {
        nativeBuildInputs = [
          pkgs.shellcheck
          pkgs.shfmt
        ];
      }
      ''
        cd ${src}
        shfmt -f lib scripts | xargs -r shellcheck
        touch $out
      '';

  # Lint Nix files with statix
  statix =
    pkgs.runCommand "check-statix"
      {
        nativeBuildInputs = [ pkgs.statix ];
      }
      ''
        cd ${src}
        statix check .
        touch $out
      '';
}
