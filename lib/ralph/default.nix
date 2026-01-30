# Ralph Wiggum Loop for AI-driven development.
#
# Provides unified ralph command with subcommands:
#   plan, logs, edit, tune, ready, step, loop, status, check, diff, sync
{
  pkgs,
  mkSandbox ? null, # only needed if using mkRalph
}:

let
  inherit (pkgs) runCommand;

  templateDir = ./template;

  # Import template module for validation
  templateModule = import ./template/default.nix { inherit (pkgs) lib; };

  # All ralph scripts bundled in a single derivation
  scripts = runCommand "ralph-scripts" { } ''
    mkdir -p $out/bin
    for script in ${./cmd}/*.sh; do
      name=$(basename "$script" .sh)
      if [ "$name" = "util" ]; then
        # util.sh is sourced, not executed directly
        cp "$script" $out/bin/util.sh
      elif [ "$name" = "ralph" ]; then
        # main entry point has no prefix
        cp "$script" $out/bin/ralph
        chmod +x $out/bin/ralph
      else
        # subcommands get ralph- prefix
        cp "$script" $out/bin/ralph-$name
        chmod +x $out/bin/ralph-$name
      fi
    done
  '';

in
{
  inherit scripts templateDir;

  # Template validation for flake checks
  # Usage: ralph.lib.mkTemplatesCheck pkgs
  mkTemplatesCheck = templateModule.mkTemplatesCheck pkgs;

  # Create ralph support for a given sandbox or profile
  # Returns: { packages, shellHook, app, sandbox }
  # - packages: list to add to devShell
  # - shellHook: shell setup for PATH and env vars
  # - app: nix app definition for `nix run`
  # - sandbox: the sandbox used (with package and profile)
  #
  # Usage:
  #   mkRalph { sandbox = mySandbox; }              # Use existing sandbox
  #   mkRalph { profile = profiles.rust; }          # Create sandbox from profile
  #   mkRalph { profile = profiles.rust; env = {}; } # Profile with extensions
  mkRalph =
    {
      sandbox ? null,
      profile ? null,
      packages ? [ ],
      mounts ? [ ],
      env ? { },
    }:
    let
      effectiveSandbox =
        if sandbox != null then
          sandbox
        else if profile != null then
          mkSandbox {
            inherit
              env
              mounts
              packages
              profile
              ;
          }
        else
          throw "mkRalph requires either 'sandbox' or 'profile' argument";

      wrapixBin = effectiveSandbox.package;
    in
    {
      inherit (effectiveSandbox) profile;
      sandbox = effectiveSandbox;

      # Packages to include in devShell
      packages = [
        scripts
        wrapixBin
      ];

      # Shell hook that ensures correct PATH ordering
      shellHook = ''
        export PATH="${scripts}/bin:${wrapixBin}/bin:$PATH"
        export RALPH_TEMPLATE_DIR="${templateDir}"
      '';

      # Nix app definition for `nix run .#ralph`
      app = {
        meta.description = "Ralph Wiggum loop in a sandbox";
        type = "app";
        program = "${pkgs.writeShellScriptBin "ralph-runner" ''
          export PATH="${scripts}/bin:${wrapixBin}/bin:$PATH"
          exec ralph "$@"
        ''}/bin/ralph-runner";
      };
    };
}
