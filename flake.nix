{
  description = "Cross-platform sandbox for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    beads.url = "github:steveyegge/beads";
  };

  outputs = { self, nixpkgs, flake-utils, beads }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        beadsPackage = beads.packages.${system}.default;
        sandboxLib = import ./lib { inherit pkgs system beadsPackage; };
        testLib = import ./lib/tests { inherit pkgs system beadsPackage; };
      in {
        # Library functions for customization
        lib = {
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
            podman
          ];
        };

        # Tests via `nix flake check`
        checks = testLib.checks;
      }
    );
}
