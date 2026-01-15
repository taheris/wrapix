{
  description = "Cross-platform sandbox for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    beads = {
      url = "github:steveyegge/beads/v0.47.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    beads-viewer = {
      url = "github:Dicklesworthstone/beads_viewer/v0.12.1";
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
            beads-viewer = inputs'.beads-viewer.packages.default;
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
            beads-viewer = inputs.beads-viewer.packages.${linuxSystem}.default;
          };

          test = import ./tests {
            inherit pkgs system;
            src = ./.;
          };

          wrapix = import ./lib { inherit pkgs system linuxPkgs; };

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
              mkSandbox
              profiles
              ;
          };

          packages = {
            default = wrapix.mkSandbox { profile = wrapix.profiles.base; };
            wrapix = wrapix.mkSandbox { profile = wrapix.profiles.base; };
            wrapix-rust = wrapix.mkSandbox { profile = wrapix.profiles.rust; };
            wrapix-notifyd = import ./lib/notify/daemon.nix { inherit pkgs; };
          }
          // pkgs.lib.optionalAttrs pkgs.stdenv.isDarwin {
            wrapix-builder = import ./lib/builder { inherit pkgs linuxPkgs; };
          };

          apps.test-darwin = {
            meta.description = "Run Darwin integration tests";
            type = "app";
            program = "${import ./tests/darwin.nix { inherit pkgs system; }}/bin/test-darwin";
          };

          apps.test-builder = {
            meta.description = "Run wrapix-builder integration tests (Darwin only)";
            type = "app";
            program = "${pkgs.writeShellScriptBin "test-builder" ''
              exec ${./tests/darwin-builder-test.sh}
            ''}/bin/test-builder";
          };

          devShells.default = wrapix.mkDevShell {
            packages =
              with pkgs;
              [
                beads
                beads-viewer
                gh
                nixfmt
                nixfmt-tree
                podman
                statix
              ]
              ++ [ (import ./lib/notify/daemon.nix { inherit pkgs; }) ];
          };
        };
    };
}
