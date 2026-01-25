# Ralph Wiggum Loop scripts package
#
# Provides unified ralph command with subcommands:
#   start, plan, logs, tune, ready, step, loop, status
# for iterative AI-driven development workflows.
{ pkgs }:

let
  inherit (builtins) readFile;
  inherit (pkgs) writeShellScriptBin;

  templateDir = ./template;

in
{
  inherit templateDir;

  # All scripts as a list for easy inclusion in devShell
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
}
