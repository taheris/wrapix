{
  description = "Cross-platform sandbox for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    beads = {
      url = "github:steveyegge/beads";
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
          # Overlay for host system packages (devShell, etc.)
          hostOverlay = final: prev: {
            beads = inputs'.beads.packages.default;
          };

          linuxSystem = if system == "aarch64-darwin" then "aarch64-linux" else system;

          linuxPkgs = import nixpkgs {
            system = linuxSystem;
            overlays = [ linuxOverlay ];
            config.allowUnfree = true;
          };

          # Overlay for Linux container packages (must use Linux binaries)
          linuxOverlay = final: prev: {
            beads = inputs.beads.packages.${linuxSystem}.default;
          };

          test = import ./tests {
            inherit pkgs system;
            src = ./.;
          };

          wrapix = import ./lib { inherit pkgs system linuxPkgs; };
          ralph = wrapix.mkRalph { profile = wrapix.profiles.base; };

        in
        {
          inherit (test) checks;
          formatter = pkgs.nixfmt-tree;

          _module.args.pkgs = import nixpkgs {
            inherit system;
            overlays = [ hostOverlay ];
            config.allowUnfree = true;
          };

          legacyPackages.lib = {
            inherit (wrapix)
              deriveProfile
              mkDevShell
              mkRalph
              mkSandbox
              profiles
              ;
          };

          packages = {
            default = wrapix.mkSandbox { profile = wrapix.profiles.base; };

            wrapix = wrapix.mkSandbox { profile = wrapix.profiles.base; };
            wrapix-rust = wrapix.mkSandbox { profile = wrapix.profiles.rust; };
            wrapix-python = wrapix.mkSandbox { profile = wrapix.profiles.python; };

            wrapix-builder = import ./lib/builder { inherit pkgs linuxPkgs; };
            wrapix-notifyd = import ./lib/notify/daemon.nix { inherit pkgs; };
          };

          apps = {
            ralph = ralph.app;
            test = test.app;
            test-lint = test.apps.lint;
            test-ralph = test.apps.ralph;
          };

          devShells.default = wrapix.mkDevShell {
            inherit (ralph) shellHook;

            packages =
              with pkgs;
              [
                beads
                gh
                nixfmt
                nixfmt-tree
                podman
                prek
                wrapix.scripts
                shellcheck
                statix
              ]
              ++ [ (import ./lib/notify/daemon.nix { inherit pkgs; }) ];
          };
        };
    };
}
