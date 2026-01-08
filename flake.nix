{
  description = "Cross-platform sandbox for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    beads.url = "github:steveyegge/beads";
  };

  outputs =
    inputs@{ nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        {
          pkgs,
          system,
          inputs',
          ...
        }:
        let
          sandboxLib = import ./lib { inherit pkgs system; };
          testLib = import ./lib/tests {
            inherit pkgs system;
            src = ./.;
          };
        in
        {
          _module.args.pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [ (final: prev: { beads = inputs'.beads.packages.default; }) ];
          };

          # Library functions for customization
          legacyPackages.lib = {
            inherit (sandboxLib) mkSandbox mkDevShell deriveProfile;
            profiles = sandboxLib.profiles;
          };

          # Ready-to-run sandboxes
          packages = {
            default = sandboxLib.mkSandbox { profile = sandboxLib.profiles.base; };
            wrapix = sandboxLib.mkSandbox { profile = sandboxLib.profiles.base; };
            wrapix-rust = sandboxLib.mkSandbox { profile = sandboxLib.profiles.rust; };
          };

          devShells.default = sandboxLib.mkDevShell {
            packages = with pkgs; [
              gh
              nixfmt-rfc-style
              podman
            ];
          };

          # Formatter for `nix fmt`
          formatter = pkgs.nixfmt-rfc-style;

          # Tests via `nix flake check`
          checks = testLib.checks;

          # Apps for running tests
          apps.test-integration = {
            type = "app";
            program = "${
              import ./lib/tests/integration-runner.nix { inherit pkgs system; }
            }/bin/test-integration";
          };
        };
    };
}
