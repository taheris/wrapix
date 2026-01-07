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
}
