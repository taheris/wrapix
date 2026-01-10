{
  description = "Cross-platform sandbox for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    beads = {
      url = "github:steveyegge/beads";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    beads-viewer = {
      url = "github:Dicklesworthstone/beads_viewer";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
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
          wrapix = import ./lib { inherit pkgs system; };
          test = import ./lib/tests {
            inherit pkgs system;
            src = ./.;
          };

        in
        {
          checks = test.checks;
          formatter = pkgs.nixfmt;

          _module.args.pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [
              (final: prev: {
                beads = inputs'.beads.packages.default;
                beads-viewer = inputs'.beads-viewer.packages.default;
              })
            ];
          };

          legacyPackages.lib = {
            inherit (wrapix) deriveProfile mkDevShell mkSandbox;
            profiles = wrapix.profiles;
          };

          packages = {
            default = wrapix.mkSandbox { profile = wrapix.profiles.base; };
            wrapix = wrapix.mkSandbox { profile = wrapix.profiles.base; };
            wrapix-rust = wrapix.mkSandbox { profile = wrapix.profiles.rust; };
          };

          apps.test-integration = {
            type = "app";
            program = "${
              import ./lib/tests/integration-runner.nix { inherit pkgs system; }
            }/bin/test-integration";
          };

          devShells.default = wrapix.mkDevShell {
            packages = with pkgs; [
              beads
              beads-viewer
              gh
              nixfmt
              nixfmt-tree
              podman
            ];
          };
        };
    };
}
