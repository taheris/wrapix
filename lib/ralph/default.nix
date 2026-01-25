# Ralph Wiggum Loop scripts package
#
# Provides ralph-loop, ralph-init, ralph-finalize, and ralph-tune commands
# for iterative AI-driven development workflows.
{ pkgs }:

let
  inherit (builtins) readFile;
  inherit (pkgs) writeShellScriptBin;

  # Read script contents
  initScript = readFile ./init.sh;
  loopScript = readFile ./loop.sh;
  tuneScript = readFile ./tune.sh;
  finalizeScript = readFile ./finalize.sh;

in
{
  # Individual script packages
  ralph-init = writeShellScriptBin "ralph-init" initScript;
  ralph-loop = writeShellScriptBin "ralph-loop" loopScript;
  ralph-tune = writeShellScriptBin "ralph-tune" tuneScript;
  ralph-finalize = writeShellScriptBin "ralph-finalize" finalizeScript;

  # Template directory path (bundled in image at /etc/wrapix/ralph-template)
  templateDir = ./template;

  # All scripts as a list for easy inclusion
  scripts = [
    (writeShellScriptBin "ralph-init" initScript)
    (writeShellScriptBin "ralph-loop" loopScript)
    (writeShellScriptBin "ralph-tune" tuneScript)
    (writeShellScriptBin "ralph-finalize" finalizeScript)
  ];
}
