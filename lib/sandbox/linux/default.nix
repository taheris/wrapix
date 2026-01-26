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
      cpus ? null,
      memoryMb ? 4096,
      deployKey ? null,
      ...
    }:
    let
      deployKeyExpr = mkDeployKeyExpr deployKey;

    in
    writeShellApplication {
      name = "wrapix";
      runtimeInputs = [ pkgs.podman ];
      text = ''
        # Ensure USER is set (may be unset in some environments)
        USER="''${USER:-$(id -un)}"

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

        # Mount notification socket directory if daemon is running
        # We mount the directory (not the socket file) so daemon restarts work
        # without needing to restart the container
        NOTIFY_SOCKET_DIR="''${XDG_RUNTIME_DIR:-$HOME/.local/share}/wrapix"
        if [ -S "$NOTIFY_SOCKET_DIR/notify.sock" ]; then
          VOLUME_ARGS="$VOLUME_ARGS -v $NOTIFY_SOCKET_DIR:/run/wrapix"
        else
          echo "Note: Notification socket not found at $NOTIFY_SOCKET_DIR/notify.sock" >&2
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
          # Stage issues.jsonl for SQLite mode (dolt-remote accessed via beads worktree in workspace mount)
          [ -f "$PROJECT_DIR/.beads/issues.jsonl" ] && cp "$PROJECT_DIR/.beads/issues.jsonl" "$BEADS_STAGING/"
          BEADS_ARGS="-v $BEADS_STAGING:/workspace/.beads"
        fi

        # Session registration for focus-aware notifications (tmux only)
        WRAPIX_SESSION_ID=""
        WRAPIX_SESSION_FILE=""
        if [ -n "''${TMUX:-}" ]; then
          WRAPIX_SESSION_ID=$(tmux display-message -p '#S:#I.#P')
          WRAPIX_SESSION_DIR="''${XDG_RUNTIME_DIR:-$HOME/.local/share}/wrapix/sessions"
          mkdir -p "$WRAPIX_SESSION_DIR"

          # Capture window ID for focus detection (niri-specific)
          WINDOW_ID=""
          if command -v niri >/dev/null 2>&1; then
            WINDOW_ID=$(niri msg -j focused-window 2>/dev/null | jq -r '.id // ""') || WINDOW_ID=""
          fi

          # Use safe filename (replace : and . with -)
          SAFE_SESSION_ID="''${WRAPIX_SESSION_ID//[:\.]/-}"
          WRAPIX_SESSION_FILE="$WRAPIX_SESSION_DIR/$SAFE_SESSION_ID.json"
          printf '{"session_id":"%s","window_id":"%s"}\n' "$WRAPIX_SESSION_ID" "$WINDOW_ID" > "$WRAPIX_SESSION_FILE"
        fi

        # Cleanup function for session file
        cleanup_session() {
          [ -n "$WRAPIX_SESSION_FILE" ] && [ -f "$WRAPIX_SESSION_FILE" ] && rm -f "$WRAPIX_SESSION_FILE"
        }
        trap cleanup_session EXIT

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
          -e "RALPH_MODE=''${RALPH_MODE:-}" \
          -e "RALPH_CMD=''${RALPH_CMD:-}" \
          -e "RALPH_ARGS=''${RALPH_ARGS:-}" \
          -e "RALPH_DIR=''${RALPH_DIR:-}" \
          -e "RALPH_DEBUG=''${RALPH_DEBUG:-}" \
          -e "HOME=/home/$USER" \
          -e "GIT_AUTHOR_NAME=$GIT_AUTHOR_NAME" \
          -e "GIT_AUTHOR_EMAIL=$GIT_AUTHOR_EMAIL" \
          -e "GIT_COMMITTER_NAME=$GIT_COMMITTER_NAME" \
          -e "GIT_COMMITTER_EMAIL=$GIT_COMMITTER_EMAIL" \
          -e "WRAPIX_SESSION_ID=$WRAPIX_SESSION_ID" \
          ''${WRAPIX_GIT_SIGN:+-e "WRAPIX_GIT_SIGN=$WRAPIX_GIT_SIGN"} \
          -w /workspace \
          docker-archive:${profileImage} \
          /entrypoint.sh
      '';
    };
}
