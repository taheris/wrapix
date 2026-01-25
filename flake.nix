{
  description = "Cross-platform sandbox for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    beads = {
      url = "github:steveyegge/beads/v0.49.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    beads-viewer = {
      url = "github:Dicklesworthstone/beads_viewer/v0.13.0";
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
            wrapix-python = wrapix.mkSandbox { profile = wrapix.profiles.python; };

            wrapix-builder = import ./lib/builder { inherit pkgs linuxPkgs; };
            wrapix-notifyd = import ./lib/notify/daemon.nix { inherit pkgs; };
          };

          apps = {
            test-darwin = {
              meta.description = "Run Darwin integration tests";
              type = "app";
              program = "${import ./tests/darwin.nix { inherit pkgs system; }}/bin/test-darwin";
            };

            test-builder = {
              meta.description = "Run wrapix-builder integration tests (Darwin only)";
              type = "app";
              program = "${pkgs.writeShellScriptBin "test-builder" ''
                exec ${./tests/builder-test.sh}
              ''}/bin/test-builder";
            };

            ralph = {
              meta.description = "Ralph Wiggum Loop - run iterative AI workflows in sandbox";
              type = "app";
              program = "${pkgs.writeShellScriptBin "ralph-container" ''
                # Parse ralph subcommand from args (default: help)
                # Usage: nix run .#ralph [subcommand] [args...] [-- project_dir]
                RALPH_CMD="''${1:-help}"
                shift || true

                # Collect remaining args until -- or end
                RALPH_ARGS=""
                while [ $# -gt 0 ] && [ "$1" != "--" ]; do
                  RALPH_ARGS="$RALPH_ARGS $1"
                  shift
                done

                # Optional project dir after --
                PROJECT_DIR=""
                if [ "$1" = "--" ]; then
                  shift
                  PROJECT_DIR="''${1:-}"
                fi

                export RALPH_MODE=1
                export RALPH_CMD
                export RALPH_ARGS
                exec ${wrapix.mkSandbox { profile = wrapix.profiles.base; }}/bin/wrapix $PROJECT_DIR
              ''}/bin/ralph-container";
            };
          };

          devShells.default =
            let
              ralphPkg = import ./lib/ralph { inherit pkgs; };
            in
            wrapix.mkDevShell {
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
                ++ [ (import ./lib/notify/daemon.nix { inherit pkgs; }) ]
                ++ ralphPkg.scripts;
              shellHook = ''
                export RALPH_TEMPLATE_DIR="${ralphPkg.templateDir}"
              '';
            };
        };
    };
}
