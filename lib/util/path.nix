# Shared path expansion utilities for sandbox implementations
#
# These functions handle ~ and $HOME expansion in mount specifications,
# used by both Linux and Darwin sandbox implementations.
_:

rec {
  # Convert ~ paths to shell expressions for host-side expansion
  # e.g., "~/.config" -> "$HOME/.config"
  expandPath =
    path:
    if builtins.substring 0 2 path == "~/" then
      "$HOME/${builtins.substring 2 (builtins.stringLength path) path}"
    else
      path;

  # Convert destination ~ paths to container home directory
  # e.g., "~/.config" -> "/home/$USER/.config"
  expandDest =
    path:
    if builtins.substring 0 2 path == "~/" then
      "/home/$USER/${builtins.substring 2 (builtins.stringLength path) path}"
    else
      path;

  # Generate mount specifications as newline-separated list for runtime processing
  # Linux format: source:dest:mode:optional|required
  # Darwin format: source:dest:optional|required (VirtioFS doesn't support modes)
  mkMountSpecs =
    {
      profile,
      includeMode ? true,
    }:
    builtins.concatStringsSep "\n" (
      map (
        m:
        let
          base = "${expandPath m.source}:${expandDest m.dest}";
          mode = if includeMode then ":${m.mode or "rw"}" else "";
          optional = if m.optional or false then "optional" else "required";
        in
        "${base}${mode}:${optional}"
      ) profile.mounts
    );
}
