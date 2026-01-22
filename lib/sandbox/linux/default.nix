# Linux sandbox implementation using a single container
{ pkgs }:

let
  knownHosts = import ../known-hosts.nix { inherit pkgs; };
  paths = import ../../util/path.nix { };
  shellLib = import ../../util/shell.nix { };

  inherit (builtins) readFile;
  inherit (paths) mkMountSpecs;
  inherit (pkgs) writeShellApplication writeText;
  inherit (shellLib)
    expandPathFn
    cleanStaleStagingDirs
    createStagingDir
    mkDeployKeyExpr
    ;

  prompt = writeText "wrapix-prompt" (readFile ../prompt.txt);

in
{
  mkSandbox =
    {
      profile,
      profileImage,
      deployKey ? null,
      cpus ? null,
      memoryMb ? 4096,
    }:
    let
      deployKeyExpr = mkDeployKeyExpr deployKey;
    in
    writeShellApplication {
      name = "wrapix";
      runtimeInputs = [ pkgs.podman ];
      text = ''
        # XDG-compliant directories for staging
        XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}"
        WRAPIX_CACHE="$XDG_CACHE_HOME/wrapix"
        PROJECT_DIR="''${1:-$(pwd)}"

        ${cleanStaleStagingDirs}

        ${createStagingDir}

        ${expandPathFn}

        # Read git author from host config (overrideable via env vars)
        GIT_AUTHOR_NAME="''${GIT_AUTHOR_NAME:-$(git config --global user.name 2>/dev/null || echo 'Wrapix Sandbox')}"
        GIT_AUTHOR_EMAIL="''${GIT_AUTHOR_EMAIL:-$(git config --global user.email 2>/dev/null || echo 'sandbox@wrapix.dev')}"
        GIT_COMMITTER_NAME="''${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
        GIT_COMMITTER_EMAIL="''${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

        # Build volume args
        VOLUME_ARGS="-v $PROJECT_DIR:/workspace:rw"

        # Mount project's .claude as container's ~/.claude for session persistence
        # This isolates container from host config while enabling /rename and /resume
        mkdir -p "$PROJECT_DIR/.claude"
        VOLUME_ARGS="$VOLUME_ARGS -v $PROJECT_DIR/.claude:/home/$USER/.claude:rw"

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
        ${mkMountSpecs {
          inherit profile;
          includeMode = true;
        }}
        MOUNTS

        # Mount SSH known_hosts file directly and system prompt
        VOLUME_ARGS="$VOLUME_ARGS -v ${knownHosts}/known_hosts:/home/$USER/.ssh/known_hosts:ro"
        VOLUME_ARGS="$VOLUME_ARGS -v ${prompt}:/etc/wrapix-prompt:ro"

        # Mount notification socket if daemon is running
        NOTIFY_SOCKET="''${XDG_RUNTIME_DIR:-$HOME/.local/share}/wrapix/notify.sock"
        if [ -S "$NOTIFY_SOCKET" ]; then
          VOLUME_ARGS="$VOLUME_ARGS -v $NOTIFY_SOCKET:/run/wrapix/notify.sock"
        else
          echo "Note: Notification socket not found at $NOTIFY_SOCKET" >&2
          echo "      Run 'nix run .#wrapix-notifyd' on host for desktop notifications" >&2
        fi

        # Mount deploy key and signing key for this repo (see scripts/setup-deploy-key)
        DEPLOY_KEY_NAME=${deployKeyExpr}
        DEPLOY_KEY="$HOME/.ssh/deploy_keys/$DEPLOY_KEY_NAME"
        SIGNING_KEY="$HOME/.ssh/deploy_keys/$DEPLOY_KEY_NAME-signing"
        DEPLOY_KEY_ARGS=""
        if [ -f "$DEPLOY_KEY" ]; then
          VOLUME_ARGS="$VOLUME_ARGS -v $DEPLOY_KEY:/home/$USER/.ssh/deploy_keys/$DEPLOY_KEY_NAME:ro"
          # Pass deploy key path to entrypoint for SSH config setup
          DEPLOY_KEY_ARGS="-e WRAPIX_DEPLOY_KEY=/home/$USER/.ssh/deploy_keys/$DEPLOY_KEY_NAME"
        fi
        if [ -f "$SIGNING_KEY" ]; then
          VOLUME_ARGS="$VOLUME_ARGS -v $SIGNING_KEY:/home/$USER/.ssh/deploy_keys/$DEPLOY_KEY_NAME-signing:ro"
          DEPLOY_KEY_ARGS="$DEPLOY_KEY_ARGS -e WRAPIX_SIGNING_KEY=/home/$USER/.ssh/deploy_keys/$DEPLOY_KEY_NAME-signing"
        fi

        # Stage .beads config files for container-local database isolation
        # Copy to staging (like Darwin) so atomic renames work inside the mount
        # bd init creates fresh database inside container from staged source
        BEADS_ARGS=""
        BEADS_STAGING=""
        if [ -d "$PROJECT_DIR/.beads" ]; then
          BEADS_STAGING="$STAGING_ROOT/beads"
          mkdir -p "$BEADS_STAGING"
          [ -f "$PROJECT_DIR/.beads/config.yaml" ] && cp "$PROJECT_DIR/.beads/config.yaml" "$BEADS_STAGING/"
          [ -f "$PROJECT_DIR/.beads/metadata.json" ] && cp "$PROJECT_DIR/.beads/metadata.json" "$BEADS_STAGING/"
          # Stage data source: dolt-remote/ for Dolt mode, issues.jsonl for SQLite mode
          [ -d "$PROJECT_DIR/.beads/dolt-remote" ] && cp -r "$PROJECT_DIR/.beads/dolt-remote" "$BEADS_STAGING/"
          [ -f "$PROJECT_DIR/.beads/issues.jsonl" ] && cp "$PROJECT_DIR/.beads/issues.jsonl" "$BEADS_STAGING/"
          BEADS_ARGS="-v $BEADS_STAGING:/workspace/.beads"
        fi

        # Calculate CPUs (use override or half of available, minimum 2)
        ${
          if cpus != null then
            ''
              CPUS=${toString cpus}
            ''
          else
            ''
              CPUS=$(($(nproc) / 2))
              [ "$CPUS" -lt 2 ] && CPUS=2
            ''
        }

        # shellcheck disable=SC2086 # Intentional word splitting for volume args
        exec podman run --rm -it \
          --cpus="$CPUS" \
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
          -e "GIT_AUTHOR_NAME=$GIT_AUTHOR_NAME" \
          -e "GIT_AUTHOR_EMAIL=$GIT_AUTHOR_EMAIL" \
          -e "GIT_COMMITTER_NAME=$GIT_COMMITTER_NAME" \
          -e "GIT_COMMITTER_EMAIL=$GIT_COMMITTER_EMAIL" \
          ''${WRAPIX_GIT_SIGN:+-e "WRAPIX_GIT_SIGN=$WRAPIX_GIT_SIGN"} \
          -w /workspace \
          docker-archive:${profileImage} \
          /entrypoint.sh
      '';
    };
}
