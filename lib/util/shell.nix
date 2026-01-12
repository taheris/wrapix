# Shared shell code snippets for sandbox implementations
#
# These are Nix strings containing shell code that can be interpolated
# into the generated launcher scripts for both Linux and Darwin.
_:

{
  # Safe path expansion function - only expands ~ and $HOME/$USER, not arbitrary commands
  # Usage: src=$(expand_path "$src")
  expandPathFn = ''
    expand_path() {
      local p="$1"
      p="''${p/#\~/$HOME}"
      p="''${p//\$HOME/$HOME}"
      p="''${p//\$USER/$USER}"
      echo "$p"
    }
  '';

  # Clean up stale staging directories from previous runs (PIDs that no longer exist)
  # Expects $WRAPIX_CACHE to be set
  cleanStaleStagingDirs = ''
    mkdir -p "$WRAPIX_CACHE/mounts"
    for stale_dir in "$WRAPIX_CACHE/mounts"/*; do
      [ -d "$stale_dir" ] || continue
      stale_pid=$(basename "$stale_dir")
      if ! kill -0 "$stale_pid" 2>/dev/null; then
        rm -rf "$stale_dir"
      fi
    done
  '';

  # Create PID-based staging directory with cleanup trap
  # Sets $STAGING_ROOT and registers EXIT trap
  # Expects $WRAPIX_CACHE to be set
  createStagingDir = ''
    STAGING_ROOT="$WRAPIX_CACHE/mounts/$$"
    mkdir -p "$STAGING_ROOT"
    trap 'rm -rf "$STAGING_ROOT"' EXIT
  '';

  # Generate deploy key name expression
  # If deployKey is provided, uses that; otherwise generates repo-hostname format at runtime
  mkDeployKeyExpr =
    deployKey:
    if deployKey != null then
      ''"${deployKey}"''
    else
      ''$(basename "$PROJECT_DIR")-$(hostname -s 2>/dev/null || hostname)'';
}
