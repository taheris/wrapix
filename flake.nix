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

    rust-overlay = {
      url = "git+ssh://git@github.com/oxalica/rust-overlay.git?ref=master&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "git+https://github.com/numtide/treefmt-nix.git?ref=main&shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.treefmt-nix.flakeModule
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        {
          config,
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
                  outputHash = "sha256-yrIlyP2fOesS74NqwaDrBK37KCjh3N1DePiF8w9ubOk=";
                };
              });

          hostOverlay = final: _prev: {
            beads = beadsFor final;
          };

          linuxSystem = if system == "aarch64-darwin" then "aarch64-linux" else system;
          linuxOverlay = final: _prev: {
            beads = beadsFor final;
          };
          linuxPkgs = import nixpkgs {
            system = linuxSystem;
            overlays = [
              inputs.rust-overlay.overlays.default
              linuxOverlay
            ];
            config.allowUnfree = true;
          };

          test = import ./tests {
            inherit pkgs system;
            src = ./.;
          };

          treefmtConfig = {
            projectRootFile = "flake.nix";
            programs = {
              deadnix.enable = true;
              nixfmt.enable = true;
              rustfmt.enable = true;
              shellcheck = {
                enable = true;
                severity = "warning";
              };
              statix.enable = true;
            };
            settings.formatter.shellcheck.excludes = [ ".envrc" ];
          };

          # Linux treefmt wrapper for sandbox images
          linuxTreefmt = inputs.treefmt-nix.lib.mkWrapper linuxPkgs treefmtConfig;

          # Extra packages baked into every sandbox image
          sandboxPackages = [ linuxTreefmt ];

          wrapix = import ./lib { inherit pkgs system linuxPkgs; };
          ralph = wrapix.mkRalph { profile = wrapix.profiles.base; };

        in
        {
          formatter = config.treefmt.build.wrapper;

          checks = test.checks // {
            treefmt = config.treefmt.build.check ./.;
          };

          _module.args.pkgs = import nixpkgs {
            inherit system;
            overlays = [
              inputs.rust-overlay.overlays.default
              hostOverlay
            ];
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
                  packages = sandboxPackages;
                };
                wrapix-rust = {
                  profile = profiles.rust;
                  packages = sandboxPackages;
                };
                wrapix-python = {
                  profile = profiles.python;
                  packages = sandboxPackages;
                };

                wrapix-mcp = {
                  profile = profiles.base;
                  packages = sandboxPackages;
                  mcpRuntime = true;
                };
                wrapix-rust-mcp = {
                  profile = profiles.rust;
                  packages = sandboxPackages;
                  mcpRuntime = true;
                };
                wrapix-python-mcp = {
                  profile = profiles.python;
                  packages = sandboxPackages;
                  mcpRuntime = true;
                };
              };
            in
            mapAttrs (_: cfg: (wrapix.mkSandbox cfg).package) sandboxes
            // {
              inherit (pkgs) beads;
              default =
                (wrapix.mkSandbox {
                  profile = profiles.base;
                  packages = sandboxPackages;
                }).package;
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
                config.treefmt.build.wrapper
                dolt
                gh
                podman
                prek
                wrapix.scripts
              ]
              ++ [ (import ./lib/notify/daemon.nix { inherit pkgs; }) ];
          };

          treefmt = treefmtConfig // {
            flakeCheck = false;
            flakeFormatter = false;
          };

        };
    };
}
