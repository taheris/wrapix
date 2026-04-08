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

  # Stage .beads config files for container-local database isolation.
  # Copies config.yaml, metadata.json, and issues.jsonl to a staging directory
  # so containers get their own .beads without mounting the host's.
  # Sets $BEADS_STAGING to the staging path (empty if no .beads found).
  # Expects $PROJECT_DIR and $STAGING_ROOT to be set.
  stageBeads = ''
    BEADS_STAGING=""
    if [ -d "$PROJECT_DIR/.beads" ]; then
      BEADS_STAGING="$STAGING_ROOT/beads"
      mkdir -p "$BEADS_STAGING"
      [ -f "$PROJECT_DIR/.beads/config.yaml" ] && cp "$PROJECT_DIR/.beads/config.yaml" "$BEADS_STAGING/"
      [ -f "$PROJECT_DIR/.beads/metadata.json" ] && cp "$PROJECT_DIR/.beads/metadata.json" "$BEADS_STAGING/"
      [ -f "$PROJECT_DIR/.beads/issues.jsonl" ] && cp "$PROJECT_DIR/.beads/issues.jsonl" "$BEADS_STAGING/"
    fi
  '';

  # Generate deploy key name expression
  # If deployKey is provided, uses that; otherwise generates repo-hostname format at runtime
  mkDeployKeyExpr =
    deployKey:
    if deployKey != null then
      ''"${deployKey}"''
    else
      ''$(basename "$PROJECT_DIR")-$(hostname -s 2>/dev/null || uname -n)'';
}
