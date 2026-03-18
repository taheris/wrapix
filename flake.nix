{
  description = "Cross-platform sandbox for Claude Code";

  inputs = {
    nixpkgs.url = "git+ssh://git@github.com/NixOS/nixpkgs.git?ref=nixos-unstable&shallow=1";

    beads = {
      url = "git+ssh://git@github.com/steveyegge/beads.git?ref=main&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts = {
      url = "git+ssh://git@github.com/hercules-ci/flake-parts.git?ref=main&shallow=1";
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
          ...
        }:
        let
          beadsFor =
            pkgs':
            (pkgs'.callPackage "${inputs.beads}/default.nix" {
              pkgs = pkgs';
              self = inputs.beads;
              buildGoModule = pkgs'.buildGo126Module;
            }).overrideAttrs
              (old: {
                goModules = old.goModules.overrideAttrs {
                  outputHash = "sha256-wcFAvGoDR9IYckWRMqPqCgPSUKmoYYyYg0dfNGDI6Go=";
                };
              });

          hostOverlay = final: prev: {
            beads = beadsFor final;
          };

          linuxSystem = if system == "aarch64-darwin" then "aarch64-linux" else system;
          linuxOverlay = final: prev: {
            beads = beadsFor final;
          };
          linuxPkgs = import nixpkgs {
            system = linuxSystem;
            overlays = [ linuxOverlay ];
            config.allowUnfree = true;
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

          packages =
            let
              inherit (builtins) mapAttrs;
              inherit (wrapix) profiles;

              sandboxes = {
                wrapix = {
                  profile = profiles.base;
                };
                wrapix-rust = {
                  profile = profiles.rust;
                };
                wrapix-python = {
                  profile = profiles.python;
                };

                wrapix-mcp = {
                  profile = profiles.base;
                  mcpRuntime = true;
                };
                wrapix-rust-mcp = {
                  profile = profiles.rust;
                  mcpRuntime = true;
                };
                wrapix-python-mcp = {
                  profile = profiles.python;
                  mcpRuntime = true;
                };
              };
            in
            mapAttrs (_: cfg: (wrapix.mkSandbox cfg).package) sandboxes
            // {
              inherit (pkgs) beads;
              default = (wrapix.mkSandbox { profile = profiles.base; }).package;
              wrapix-builder = import ./lib/builder { inherit pkgs linuxPkgs; };
              wrapix-notifyd = import ./lib/notify/daemon.nix { inherit pkgs; };
              tmux-mcp = import ./lib/mcp/tmux/mcp-server.nix { inherit pkgs; };
            };

          apps = {
            ralph = ralph.app;
            test = test.app;
            test-lint = test.apps.lint;
            test-ralph = test.apps.ralph;
          };

          devShells.default = wrapix.mkDevShell {
            shellHook = ''
              ${ralph.shellHook}
            '';

            packages =
              with pkgs;
              [
                beads
                dolt
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
