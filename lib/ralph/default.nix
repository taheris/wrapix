# Ralph Wiggum Loop for AI-driven development.
#
# Provides unified ralph command with subcommands:
#   plan, logs, edit, tune, ready, step, loop, status, check, diff
{
  pkgs,
  mkSandbox ? null, # only needed if using mkRalph
}:

let
  inherit (builtins) readFile;
  inherit (pkgs) buildEnv writeShellScriptBin;

  templateDir = ./template;

  # Shared utilities - must be first so other scripts can source it
  utilScript = pkgs.writeTextFile {
    name = "util.sh";
    text = readFile ./cmd/util.sh;
    destination = "/bin/util.sh";
  };

  scripts = [
    utilScript
    (writeShellScriptBin "ralph" (readFile ./cmd/ralph.sh))
    (writeShellScriptBin "ralph-plan" (readFile ./cmd/plan.sh))
    (writeShellScriptBin "ralph-logs" (readFile ./cmd/logs.sh))
    (writeShellScriptBin "ralph-ready" (readFile ./cmd/ready.sh))
    (writeShellScriptBin "ralph-step" (readFile ./cmd/step.sh))
    (writeShellScriptBin "ralph-loop" (readFile ./cmd/loop.sh))
    (writeShellScriptBin "ralph-status" (readFile ./cmd/status.sh))
    (writeShellScriptBin "ralph-check" (readFile ./cmd/check.sh))
    (writeShellScriptBin "ralph-diff" (readFile ./cmd/diff.sh))
  ];

  ralphEnv = buildEnv {
    name = "ralph-env";
    paths = scripts;
  };

in
{
  inherit templateDir scripts;

  # Create ralph support for a given wrapix profile
  # Returns: { packages, shellHook, app }
  # - packages: list to add to devShell
  # - shellHook: shell setup for PATH and env vars
  # - app: nix app definition for `nix run`
  mkRalph =
    {
      profile,
      packages ? [ ],
      mounts ? [ ],
      env ? { },
    }:
    let
      wrapixBin = mkSandbox {
        inherit
          profile
          packages
          mounts
          env
          ;
      };
    in
    {
      # Packages to include in devShell (wrapixBin + ralph scripts)
      packages = [ wrapixBin ] ++ scripts;

      # Shell hook that ensures correct PATH ordering
      shellHook = ''
        export PATH="${ralphEnv}/bin:${wrapixBin}/bin:$PATH"
        export RALPH_TEMPLATE_DIR="${templateDir}"
      '';

      # Nix app definition for `nix run .#ralph`
      app = {
        meta.description = "Ralph Wiggum loop in a sandbox";
        type = "app";
        program = "${writeShellScriptBin "ralph-runner" ''
          export PATH="${ralphEnv}/bin:${wrapixBin}/bin:$PATH"
          exec ralph "$@"
        ''}/bin/ralph-runner";
      };
    };
}
