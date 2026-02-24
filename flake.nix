{
  description = "Cross-platform sandbox for Claude Code";

  inputs = {
    nixpkgs.url = "git+ssh://git@github.com/NixOS/nixpkgs.git?ref=nixos-unstable&shallow=1";

    beads = {
      url = "git+ssh://git@github.com/steveyegge/beads.git?ref=refs/tags/v0.56.1&shallow=1";
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
          inputs',
          ...
        }:
        let
          # Fix stale vendorHash in upstream beads v0.56.1 for Go 1.25.x
          beadsFor =
            pkgs':
            (pkgs'.callPackage "${inputs.beads}/default.nix" {
              pkgs = pkgs';
              self = inputs.beads;
            }).overrideAttrs
              (old: {
                goModules = old.goModules.overrideAttrs {
                  outputHash = "sha256-DlEnIVNLHWetwQxTmUNOAuDbHGZ9mmLdITwDdviphPs=";
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

                wrapix-debug = {
                  profile = profiles.base;
                  mcp.tmux-debug = { };
                };
                wrapix-rust-debug = {
                  profile = profiles.rust;
                  mcp.tmux-debug = { };
                };
                wrapix-debug-audit = {
                  profile = profiles.base;
                  mcp.tmux-debug.audit = "/workspace/.debug-audit.log";
                };
              };
            in
            mapAttrs (_: cfg: (wrapix.mkSandbox cfg).package) sandboxes
            // {
              default = (wrapix.mkSandbox { profile = profiles.base; }).package;
              wrapix-builder = import ./lib/builder { inherit pkgs linuxPkgs; };
              wrapix-notifyd = import ./lib/notify/daemon.nix { inherit pkgs; };
              tmux-debug-mcp = import ./lib/mcp/tmux/mcp-server.nix { inherit pkgs; };
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
