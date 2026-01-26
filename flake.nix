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

          apps =
            let
              ralph = wrapix.mkRalph { profile = wrapix.profiles.base; };
              isDarwin = system == "aarch64-darwin";

            in
            {
              ralph = ralph.app;

              test = {
                meta.description = "Run all tests (darwin tests skip gracefully on Linux)";
                type = "app";
                program = "${pkgs.writeShellScriptBin "test-all" ''
                  set -euo pipefail

                  FAILED=0
                  DARWIN_SKIPPED=0

                  echo "=== Wrapix Test Suite ==="
                  echo ""

                  # Run nix flake checks (smoke, ralph, lint, darwin logic tests)
                  echo "----------------------------------------"
                  echo "Running: Nix Flake Checks"
                  echo "----------------------------------------"
                  if ${pkgs.nix}/bin/nix flake check --impure 2>&1; then
                    echo "PASS: Nix flake checks"
                  else
                    echo "FAIL: Nix flake checks"
                    FAILED=1
                  fi
                  echo ""

                  # Darwin integration tests (container runtime)
                  echo "----------------------------------------"
                  echo "Running: Darwin Integration Tests"
                  echo "----------------------------------------"
                  ${
                    if isDarwin then
                      ''
                        if ${import ./tests/darwin { inherit pkgs system; }}/bin/test-darwin; then
                          echo "PASS: Darwin integration tests"
                        else
                          echo "FAIL: Darwin integration tests"
                          FAILED=1
                        fi
                      ''
                    else
                      ''
                        echo "SKIP: Darwin tests (not on Darwin)"
                        DARWIN_SKIPPED=1
                      ''
                  }
                  echo ""

                  # Summary
                  echo "========================================"
                  if [ "$FAILED" -eq 0 ]; then
                    if [ "$DARWIN_SKIPPED" -eq 1 ]; then
                      echo "ALL TESTS PASSED (Darwin tests skipped)"
                    else
                      echo "ALL TESTS PASSED"
                    fi
                    exit 0
                  else
                    echo "SOME TESTS FAILED"
                    exit 1
                  fi
                ''}/bin/test-all";
              };

              test-darwin = {
                meta.description = "Run Darwin integration tests";
                type = "app";
                program = "${import ./tests/darwin { inherit pkgs system; }}/bin/test-darwin";
              };

              test-builder = {
                meta.description = "Run wrapix-builder integration tests (Darwin only)";
                type = "app";
                program = "${pkgs.writeShellScriptBin "test-builder" ''
                  exec ${./tests/builder-test.sh}
                ''}/bin/test-builder";
              };
            };

          devShells.default =
            let
              ralph = wrapix.mkRalph { profile = wrapix.profiles.base; };

            in
            wrapix.mkDevShell {
              packages =
                with pkgs;
                [
                  beads
                  gh
                  nixfmt
                  nixfmt-tree
                  podman
                  statix
                ]
                ++ [ (import ./lib/notify/daemon.nix { inherit pkgs; }) ]
                ++ ralph.packages;

              inherit (ralph) shellHook;
            };
        };
    };
}
