# Linux sandbox implementation using a single container
#
# Container isolation provides:
# - Filesystem isolation (only /workspace is accessible)
# - Process isolation (can't see/interact with host processes)
# - User namespace mapping (files created have correct host ownership)
#
# Network is open for web research - container isolation is the security boundary.

{ pkgs }:

let
  systemPrompt = builtins.readFile ../sandbox-prompt.txt;

  # Convert ~ paths to shell expressions
  expandPath = path:
    if builtins.substring 0 2 path == "~/"
    then ''$HOME/${builtins.substring 2 (builtins.stringLength path) path}''
    else path;

  # Convert destination ~ paths to container home
  expandDest = path:
    if builtins.substring 0 2 path == "~/"
    then ''/home/$USER/${builtins.substring 2 (builtins.stringLength path) path}''
    else path;

  # Generate shell code for a single mount
  mkMountLine = mount:
    let
      src = expandPath mount.source;
      dst = expandDest mount.dest;
      mode = mount.mode or "rw";
      optional = mount.optional or false;
    in
      if optional
      then ''[ -e "${src}" ] && VOLUME_ARGS="$VOLUME_ARGS -v ${src}:${dst}:${mode}"''
      else ''VOLUME_ARGS="$VOLUME_ARGS -v ${src}:${dst}:${mode}"'';

  # Generate all mount lines from profile
  mkMountLines = profile:
    builtins.concatStringsSep "\n  " (map mkMountLine profile.mounts);

in
{
  mkSandbox = { profile, profileImage, entrypoint }:
    pkgs.writeShellScriptBin "wrapix" ''
  set -euo pipefail

  PROJECT_DIR="''${1:-$(pwd)}"

  WRAPIX_PROMPT='${systemPrompt}'

  # Build volume args from profile
  VOLUME_ARGS="-v $PROJECT_DIR:/workspace:rw"
  ${mkMountLines profile}

  # Mount .beads tracked files only (not gitignored runtime files like db, socket, daemon)
  # This prevents container bd from interfering with host daemon's SQLite connection
  BEADS_DIR="$PROJECT_DIR/.beads"
  if [ -d "$BEADS_DIR" ]; then
    # Create tmpfs overlay for .beads to hide host's runtime files
    VOLUME_ARGS="$VOLUME_ARGS --mount type=tmpfs,destination=/workspace/.beads"
    # Mount only tracked files (JSONL, config) into the tmpfs
    for f in issues.jsonl interactions.jsonl config.yaml metadata.json; do
      [ -f "$BEADS_DIR/$f" ] && VOLUME_ARGS="$VOLUME_ARGS -v $BEADS_DIR/$f:/workspace/.beads/$f:rw"
    done
  fi

  exec podman run --rm -it \
    --network=pasta \
    --userns=keep-id \
    --entrypoint /bin/bash \
    $VOLUME_ARGS \
    -e "HOME=/home/$USER" \
    -e "ANTHROPIC_API_KEY=''${ANTHROPIC_API_KEY:-}" \
    -e "WRAPIX_PROMPT=$WRAPIX_PROMPT" \
    -e "BD_NO_DB=1" \
    -w /workspace \
    docker-archive:${profileImage} \
    -c 'claude --dangerously-skip-permissions --append-system-prompt "$WRAPIX_PROMPT"'
  '';
}
