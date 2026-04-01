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

    gascity = {
      url = "git+ssh://git@github.com/gastownhall/gascity.git?ref=main&shallow=1";
      flake = false;
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
        ./tests/flake-module.nix
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      flake.nixosModules.city = ./modules/city.nix;
      flake.nixosModules.default = ./modules/city.nix;

      perSystem =
        {
          config,
          pkgs,
          self',
          system,
          ...
        }:
        let
          hostOverlay = final: _prev: {
            beads = beadsFor final;
            gc = gcFor final;
          };

          beadsFor =
            pkgs':
            (pkgs'.callPackage "${inputs.beads}/default.nix" {
              pkgs = pkgs';
              self = inputs.beads;
              buildGoModule = pkgs'.buildGo126Module;
            }).overrideAttrs
              (old: {
                nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs'.pkg-config ];
                buildInputs = (old.buildInputs or [ ]) ++ [ pkgs'.icu ];
                goModules = old.goModules.overrideAttrs {
                  outputHash = "sha256-7DJgqJX2HDa9gcGD8fLNHLIXvGAEivYeDYx3snCUyCE=";
                };
              });

          gcFor =
            pkgs':
            pkgs'.buildGo126Module {
              pname = "gc";
              version = "dev";
              src = inputs.gascity;
              subPackages = [ "cmd/gc" ];
              vendorHash = "sha256-ywH32kh5p5W3TttgolibegBA+ZDC7yfNSVxJkoZcQ8E=";
              doCheck = false;
            };

          linuxSystem = if system == "aarch64-darwin" then "aarch64-linux" else system;
          linuxOverlay = final: _prev: {
            beads = beadsFor final;
            gc = gcFor final;
          };
          linuxPkgs = import nixpkgs {
            system = linuxSystem;
            overlays = [
              inputs.rust-overlay.overlays.default
              linuxOverlay
            ];
            config.allowUnfree = true;
          };

          sandboxPackages = [ (inputs.treefmt-nix.lib.mkWrapper linuxPkgs treefmtConfig) ];

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

          wrapix = import ./lib { inherit pkgs system linuxPkgs; };
          city = wrapix.mkCity { profile = wrapix.profiles.base; };

        in
        {
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
              mkCity
              mkDevShell
              mkRalph
              mkSandbox
              profiles
              ;
          };

          packages =
            let
              inherit (wrapix) profiles;

              mkSandboxPkg = cfg: (wrapix.mkSandbox (cfg // { packages = sandboxPackages; })).package;

              sandboxPkgs = builtins.mapAttrs (_: mkSandboxPkg) {
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
            sandboxPkgs
            // {
              inherit (pkgs) beads gc;
              default = sandboxPkgs.wrapix;
              wrapix-builder = import ./lib/builder { inherit pkgs linuxPkgs; };
              wrapix-notifyd = import ./lib/notify/daemon.nix { inherit pkgs; };
              tmux-mcp = import ./lib/mcp/tmux/mcp-server.nix { inherit pkgs; };
            };

          apps = {
            city = city.app;
            ralph = city.ralph.app;
          };

          devShells.default = wrapix.mkDevShell {
            inherit (city) shellHook;
            packages = city.packages ++ [
              config.treefmt.build.wrapper
              pkgs.gh
              pkgs.podman
              self'.packages.wrapix-notifyd
            ];
          };

          treefmt = treefmtConfig;
        };
    };
}
