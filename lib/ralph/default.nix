# Ralph Wiggum Loop scripts package
#
# Provides unified ralph command with subcommands:
#   start, plan, logs, tune, ready, step, loop, status
# for iterative AI-driven development workflows.
{ pkgs }:

let
  inherit (builtins) readFile;
  inherit (pkgs) writeShellScriptBin;

  # Read script contents
  ralphScript = readFile ./ralph.sh;
  startScript = readFile ./start.sh;
  planScript = readFile ./plan.sh;
  logsScript = readFile ./logs.sh;
  tuneScript = readFile ./tune.sh;
  readyScript = readFile ./ready.sh;
  stepScript = readFile ./step.sh;
  loopScript = readFile ./loop.sh;
  statusScript = readFile ./status.sh;

in
{
  # Individual script packages
  ralph = writeShellScriptBin "ralph" ralphScript;
  ralph-start = writeShellScriptBin "ralph-start" startScript;
  ralph-plan = writeShellScriptBin "ralph-plan" planScript;
  ralph-logs = writeShellScriptBin "ralph-logs" logsScript;
  ralph-tune = writeShellScriptBin "ralph-tune" tuneScript;
  ralph-ready = writeShellScriptBin "ralph-ready" readyScript;
  ralph-step = writeShellScriptBin "ralph-step" stepScript;
  ralph-loop = writeShellScriptBin "ralph-loop" loopScript;
  ralph-status = writeShellScriptBin "ralph-status" statusScript;

  # Template directory path (bundled in image at /etc/wrapix/ralph-template)
  templateDir = ./template;

  # All scripts as a list for easy inclusion
  scripts = [
    (writeShellScriptBin "ralph" ralphScript)
    (writeShellScriptBin "ralph-start" startScript)
    (writeShellScriptBin "ralph-plan" planScript)
    (writeShellScriptBin "ralph-logs" logsScript)
    (writeShellScriptBin "ralph-tune" tuneScript)
    (writeShellScriptBin "ralph-ready" readyScript)
    (writeShellScriptBin "ralph-step" stepScript)
    (writeShellScriptBin "ralph-loop" loopScript)
    (writeShellScriptBin "ralph-status" statusScript)
  ];
}
