# Ralph Wiggum Loop scripts package
#
# Provides unified ralph command with subcommands:
#   init, plan, logs, tune, ready, step, loop
# for iterative AI-driven development workflows.
{ pkgs }:

let
  inherit (builtins) readFile;
  inherit (pkgs) writeShellScriptBin;

  # Read script contents
  ralphScript = readFile ./ralph.sh;
  initScript = readFile ./init.sh;
  planScript = readFile ./plan.sh;
  logsScript = readFile ./logs.sh;
  tuneScript = readFile ./tune.sh;
  readyScript = readFile ./ready.sh;
  stepScript = readFile ./step.sh;
  loopScript = readFile ./loop.sh;

in
{
  # Individual script packages
  ralph = writeShellScriptBin "ralph" ralphScript;
  ralph-init = writeShellScriptBin "ralph-init" initScript;
  ralph-plan = writeShellScriptBin "ralph-plan" planScript;
  ralph-logs = writeShellScriptBin "ralph-logs" logsScript;
  ralph-tune = writeShellScriptBin "ralph-tune" tuneScript;
  ralph-ready = writeShellScriptBin "ralph-ready" readyScript;
  ralph-step = writeShellScriptBin "ralph-step" stepScript;
  ralph-loop = writeShellScriptBin "ralph-loop" loopScript;

  # Template directory path (bundled in image at /etc/wrapix/ralph-template)
  templateDir = ./template;

  # All scripts as a list for easy inclusion
  scripts = [
    (writeShellScriptBin "ralph" ralphScript)
    (writeShellScriptBin "ralph-init" initScript)
    (writeShellScriptBin "ralph-plan" planScript)
    (writeShellScriptBin "ralph-logs" logsScript)
    (writeShellScriptBin "ralph-tune" tuneScript)
    (writeShellScriptBin "ralph-ready" readyScript)
    (writeShellScriptBin "ralph-step" stepScript)
    (writeShellScriptBin "ralph-loop" loopScript)
  ];
}
