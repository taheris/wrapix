{
  description = "Cross-platform sandbox for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        sandboxLib = import ./lib { inherit pkgs system; };
        testLib = import ./lib/tests { inherit pkgs system; };
      in {
        # Library functions for customization
        lib = {
          inherit (sandboxLib) mkSandbox mkDevShell deriveProfile;
          profiles = sandboxLib.profiles;
        };

        # Ready-to-run sandboxes
        packages = {
          default = sandboxLib.mkSandbox sandboxLib.profiles.base;
          wrapix = sandboxLib.mkSandbox sandboxLib.profiles.base;
          wrapix-rust = sandboxLib.mkSandbox sandboxLib.profiles.rust;
        };

        devShells.default = sandboxLib.mkDevShell {
          packages = with pkgs; [
            podman
            slirp4netns
          ];
        };

        # Tests via `nix flake check`
        checks = testLib.checks;
      }
    );
}
