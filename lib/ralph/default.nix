# Ralph Wiggum Loop for AI-driven development.
#
# Provides unified ralph command with subcommands:
#   start, plan, logs, tune, ready, step, loop, status
{
  pkgs,
  mkSandbox ? null, # only needed if using mkRalph
}:

let
  inherit (builtins) readFile;
  inherit (pkgs) buildEnv writeShellScriptBin;

  templateDir = ./template;

  scripts = [
    (writeShellScriptBin "ralph" (readFile ./ralph.sh))
    (writeShellScriptBin "ralph-start" (readFile ./start.sh))
    (writeShellScriptBin "ralph-plan" (readFile ./plan.sh))
    (writeShellScriptBin "ralph-logs" (readFile ./logs.sh))
    (writeShellScriptBin "ralph-tune" (readFile ./tune.sh))
    (writeShellScriptBin "ralph-ready" (readFile ./ready.sh))
    (writeShellScriptBin "ralph-step" (readFile ./step.sh))
    (writeShellScriptBin "ralph-loop" (readFile ./loop.sh))
    (writeShellScriptBin "ralph-status" (readFile ./status.sh))
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
    { profile }:
    let
      wrapixBin = mkSandbox { inherit profile; };
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
