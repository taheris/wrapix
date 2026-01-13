# Shared path expansion utilities for sandbox implementations
#
# These functions handle ~ and $HOME expansion in mount specifications,
# used by both Linux and Darwin sandbox implementations.
_:

let
  inherit (builtins) concatStringsSep stringLength substring;

  # Convert ~ paths to shell expressions for host-side expansion
  # e.g., "~/.config" -> "$HOME/.config"
  expandPath =
    str: if substring 0 2 str == "~/" then "$HOME/${substring 2 (stringLength str) str}" else str;

  # Convert destination ~ paths to container home directory
  # e.g., "~/.config" -> "/home/$USER/.config"
  expandDest =
    str: if substring 0 2 str == "~/" then "/home/$USER/${substring 2 (stringLength str) str}" else str;

in
{
  inherit expandDest expandPath;

  # Generate mount specifications as newline-separated list for runtime processing
  # Linux format: source:dest:mode:optional|required
  # Darwin format: source:dest:optional|required (VirtioFS doesn't support modes)
  mkMountSpecs =
    {
      profile,
      includeMode ? true,
    }:
    concatStringsSep "\n" (
      map (
        mount:
        let
          base = "${expandPath mount.source}:${expandDest mount.dest}";
          mode = if includeMode then ":${mount.mode or "rw"}" else "";
          optional = if mount.optional or false then "optional" else "required";
        in
        "${base}${mode}:${optional}"
      ) profile.mounts
    );
}
