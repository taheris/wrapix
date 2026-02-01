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

              # Sandbox configurations: profile + optional MCP servers
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
                wrapix-debug-audited = {
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
