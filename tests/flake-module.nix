# Flake-parts module that exports test checks and apps
# This allows natural module merging with treefmt-nix's checks
{ self, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      test = import ./. {
        inherit pkgs system;
        src = self;
      };
    in
    {
      inherit (test) checks;

      apps = {
        test = test.app;
        test-lint = test.apps.lint;
        test-ralph = test.apps.ralph;
      };
    };
}
