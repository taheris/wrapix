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
  systemPromptFile = pkgs.writeText "wrapix-prompt" (builtins.readFile ../sandbox-prompt.txt);
  knownHosts = import ../known-hosts.nix { inherit pkgs; };

  # Convert ~ paths to shell expressions
  expandPath =
    path:
    if builtins.substring 0 2 path == "~/" then
      ''$HOME/${builtins.substring 2 (builtins.stringLength path) path}''
    else
      path;

  # Convert destination ~ paths to container home
  expandDest =
    path:
    if builtins.substring 0 2 path == "~/" then
      ''/home/$USER/${builtins.substring 2 (builtins.stringLength path) path}''
    else
      path;

  # Generate mount specs as newline-separated list for runtime processing
  # Format: source:dest:mode:optional|required
  mkMountSpecs =
    profile:
    builtins.concatStringsSep "\n" (
      map (
        m:
        "${expandPath m.source}:${expandDest m.dest}:${m.mode or "rw"}:${
          if m.optional or false then "optional" else "required"
        }"
      ) profile.mounts
    );

in
{
  mkSandbox =
    {
      profile,
      profileImage,
      deployKey ? null,
      cpus ? 4,
      memoryMb ? 4096,
    }:
    let
      # If deployKey is null, default to repo-hostname format at runtime
      deployKeyExpr =
        if deployKey != null then
          ''"${deployKey}"''
        else
          ''$(basename "$PROJECT_DIR")-$(hostname -s 2>/dev/null || hostname)'';
    in
    pkgs.writeShellApplication {
      name = "wrapix";
      runtimeInputs = [ pkgs.podman ];
      text = ''
      # XDG-compliant directories for staging
      XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}"
      WRAPIX_CACHE="$XDG_CACHE_HOME/wrapix"
      PROJECT_DIR="''${1:-$(pwd)}"

      # Clean up stale staging dirs from previous runs (PIDs that no longer exist)
      mkdir -p "$WRAPIX_CACHE/mounts"
      for stale_dir in "$WRAPIX_CACHE/mounts"/*; do
        [ -d "$stale_dir" ] || continue
        stale_pid=$(basename "$stale_dir")
        if ! kill -0 "$stale_pid" 2>/dev/null; then
          rm -rf "$stale_dir"
        fi
      done

      # Create staging directory for this run (cleaned up on exit)
      STAGING_ROOT="$WRAPIX_CACHE/mounts/$$"
      mkdir -p "$STAGING_ROOT"
      trap 'rm -rf "$STAGING_ROOT"' EXIT

      # Safe path expansion: only expand ~ and $HOME/$USER, not arbitrary commands
      expand_path() {
        local p="$1"
        p="''${p/#\~/$HOME}"
        p="''${p//\$HOME/$HOME}"
        p="''${p//\$USER/$USER}"
        echo "$p"
      }

      # Build volume args
      VOLUME_ARGS="-v $PROJECT_DIR:/workspace:rw"
      dir_idx=0

      # Process profile mounts - stage directories to dereference symlinks
      while IFS=: read -r src dest mode optional; do
        [ -z "$src" ] && continue
        src=$(expand_path "$src")
        dest=$(expand_path "$dest")

        if [ ! -e "$src" ]; then
          [ "$optional" = "optional" ] && continue
          echo "Error: Mount source not found: $src"
          exit 1
        fi

        if [ -d "$src" ]; then
          # Stage directory with cp -rL to dereference symlinks (e.g., nix store)
          staging="$STAGING_ROOT/dir$dir_idx"
          mkdir -p "$staging"
          cp -rL "$src/." "$staging/"
          dir_idx=$((dir_idx + 1))
          VOLUME_ARGS="$VOLUME_ARGS -v $staging:$dest:$mode"
        else
          # Files can be mounted directly
          VOLUME_ARGS="$VOLUME_ARGS -v $src:$dest:$mode"
        fi
      done <<'MOUNTS'
      ${mkMountSpecs profile}
      MOUNTS

      # Mount SSH known_hosts file directly and system prompt
      VOLUME_ARGS="$VOLUME_ARGS -v ${knownHosts}/known_hosts:/home/$USER/.ssh/known_hosts:ro"
      VOLUME_ARGS="$VOLUME_ARGS -v ${systemPromptFile}:/etc/wrapix-prompt:ro"

      # Mount deploy key for this repo (see scripts/setup-deploy-key)
      DEPLOY_KEY_NAME=${deployKeyExpr}
      DEPLOY_KEY="$HOME/.ssh/deploy_keys/$DEPLOY_KEY_NAME"
      DEPLOY_KEY_ARGS=""
      if [ -f "$DEPLOY_KEY" ]; then
        VOLUME_ARGS="$VOLUME_ARGS -v $DEPLOY_KEY:/home/$USER/.ssh/deploy_keys/$DEPLOY_KEY_NAME:ro"
        # Pass deploy key path to entrypoint for SSH config setup
        DEPLOY_KEY_ARGS="-e WRAPIX_DEPLOY_KEY=/home/$USER/.ssh/deploy_keys/$DEPLOY_KEY_NAME"
      fi

      # Stage .beads config files for container-local database isolation
      # Copy to staging (like Darwin) so atomic renames work inside the mount
      # bd init creates fresh beads.db inside container from the staged JSONL
      BEADS_ARGS=""
      BEADS_STAGING=""
      if [ -d "$PROJECT_DIR/.beads" ]; then
        BEADS_STAGING="$STAGING_ROOT/beads"
        mkdir -p "$BEADS_STAGING"
        [ -f "$PROJECT_DIR/.beads/config.yaml" ] && cp "$PROJECT_DIR/.beads/config.yaml" "$BEADS_STAGING/"
        [ -f "$PROJECT_DIR/.beads/issues.jsonl" ] && cp "$PROJECT_DIR/.beads/issues.jsonl" "$BEADS_STAGING/"
        BEADS_ARGS="-v $BEADS_STAGING:/workspace/.beads"
      fi

      # shellcheck disable=SC2086 # Intentional word splitting for volume args
      exec podman run --rm -it \
        --cpus=${toString cpus} \
        --memory=${toString memoryMb}m \
        --network=pasta \
        --userns=keep-id \
        --passwd-entry "$USER:*:$(id -u):$(id -g)::/home/$USER:/bin/bash" \
        --mount type=tmpfs,destination=/home/$USER \
        $VOLUME_ARGS \
        $BEADS_ARGS \
        $DEPLOY_KEY_ARGS \
        -e "BD_NO_DAEMON=1" \
        -e "CLAUDE_CODE_OAUTH_TOKEN=''${CLAUDE_CODE_OAUTH_TOKEN:-}" \
        -e "HOME=/home/$USER" \
        -w /workspace \
        docker-archive:${profileImage} \
        /entrypoint.sh
    '';
    };
}
