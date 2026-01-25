# Context pinning utility for AI agents
#
# Provides a function to read specs/README.md for better AI search hit rates.
# Used by sandbox entrypoints and ralph commands.
{ pkgs }:

let
  inherit (pkgs) writeShellScriptBin;
in
{
  # Script that outputs context from specs/README.md
  pin-context = writeShellScriptBin "pin-context" ''
    # Pin context by reading specs/README.md for better AI search hit rates
    specs_readme="''${1:-specs/README.md}"
    if [ -f "$specs_readme" ]; then
      echo "Context pinned: $specs_readme" >&2
      cat "$specs_readme"
    else
      echo "No specs/README.md found" >&2
      echo ""
    fi
  '';
}
