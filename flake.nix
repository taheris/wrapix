{
  description = "Cross-platform sandbox for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        sandboxLib = import ./lib { inherit pkgs system; };
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
          wrapix-go = sandboxLib.mkSandbox sandboxLib.profiles.go;
          wrapix-python = sandboxLib.mkSandbox sandboxLib.profiles.python;
          wrapix-js = sandboxLib.mkSandbox sandboxLib.profiles.js;
          wrapix-nix = sandboxLib.mkSandbox sandboxLib.profiles.nix;
          wrapix-devops = sandboxLib.mkSandbox sandboxLib.profiles.devops;
        };

        devShells.default = sandboxLib.mkDevShell {
          packages = with pkgs; [ podman ];
        };
      }
    );
}
