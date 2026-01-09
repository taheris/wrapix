# Darwin sandbox using Apple container CLI (macOS 26+)
{ pkgs, linuxPkgs }:

let
  systemPrompt = builtins.readFile ../sandbox-prompt.txt;
  knownHosts = import ../known-hosts.nix { inherit pkgs; };

  expandPath =
    path:
    if builtins.substring 0 2 path == "~/" then
      ''$HOME/${builtins.substring 2 (builtins.stringLength path) path}''
    else
      path;

  expandDest =
    path:
    if builtins.substring 0 2 path == "~/" then
      # HOME is /home/$USER in the container
      ''/home/$USER/${builtins.substring 2 (builtins.stringLength path) path}''
    else
      path;

  # Generate mount specs as newline-separated list for runtime processing
  # Format: source:dest:optional|required
  mkMountSpecs =
    profile:
    builtins.concatStringsSep "\n" (
      map (
        m:
        "${expandPath m.source}:${expandDest m.dest}:${
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
      ...
    }:
    let
      # If deployKey is null, default to repo-hostname format at runtime
      deployKeyExpr = if deployKey != null then ''"${deployKey}"'' else ''$(basename "$PROJECT_DIR")-$(hostname -s 2>/dev/null || hostname)'';
    in
    pkgs.writeShellScriptBin "wrapix" ''
            set -euo pipefail

            # XDG-compliant directories
            XDG_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
            XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}"
            WRAPIX_DATA="$XDG_DATA_HOME/wrapix"
            WRAPIX_CACHE="$XDG_CACHE_HOME/wrapix"
            PROJECT_DIR="''${1:-$(pwd)}"

            # Check macOS version
            if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
              echo "Error: macOS 26+ required (current: $(sw_vers -productVersion))"
              exit 1
            fi

            # Ensure container system is running
            if ! container system status >/dev/null 2>&1; then
              echo "Starting container system..."
              container system start
              sleep 2
            fi

            # Load profile image if needed (reload if image hash changed)
            PROFILE_IMAGE="wrapix-${profile.name}:latest"
            IMAGE_VERSION_FILE="$WRAPIX_DATA/images/wrapix-${profile.name}.version"
            CURRENT_IMAGE_HASH="${profileImage}"
            mkdir -p "$WRAPIX_DATA/images"
            if ! container image inspect "$PROFILE_IMAGE" >/dev/null 2>&1 || \
               [ ! -f "$IMAGE_VERSION_FILE" ] || [ "$(cat "$IMAGE_VERSION_FILE")" != "$CURRENT_IMAGE_HASH" ]; then
              echo "Loading profile image..."
              # Delete old image if exists
              container image delete "$PROFILE_IMAGE" 2>/dev/null || true
              # Convert Docker-format tar to OCI-archive format
              OCI_TAR="$WRAPIX_CACHE/profile-image-oci.tar"
              mkdir -p "$WRAPIX_CACHE"
              ${pkgs.skopeo}/bin/skopeo --insecure-policy copy "docker-archive:${profileImage}" "oci-archive:$OCI_TAR"
              # Load and capture the digest from output (format: "untagged@sha256:...")
              LOAD_OUTPUT=$(container image load --input "$OCI_TAR" 2>&1)
              LOADED_REF=$(echo "$LOAD_OUTPUT" | grep -oE 'untagged@sha256:[a-f0-9]+' | head -1)
              if [ -n "$LOADED_REF" ]; then
                container image tag "$LOADED_REF" "$PROFILE_IMAGE"
              fi
              rm -f "$OCI_TAR"
              echo "$CURRENT_IMAGE_HASH" > "$IMAGE_VERSION_FILE"
            fi

            # Build mount arguments at runtime (check file vs directory)
            MOUNT_ARGS=""
            while IFS=: read -r src dest optional; do
              [ -z "$src" ] && continue
              # Expand shell variables in paths
              src=$(eval echo "$src")
              dest=$(eval echo "$dest")

              if [ ! -e "$src" ]; then
                [ "$optional" = "optional" ] && continue
                echo "Error: Mount source not found: $src"
                exit 1
              fi

              MOUNT_ARGS="$MOUNT_ARGS -v $src:$dest"
            done <<'MOUNTS'
      ${mkMountSpecs profile}
      MOUNTS

            # Add SSH known_hosts
            MOUNT_ARGS="$MOUNT_ARGS -v ${knownHosts}:/home/\$USER/.ssh/known_hosts"

            # Add deploy key mount if present
            DEPLOY_KEY="$HOME/.ssh/deploy_keys/${deployKeyExpr}"
            [ -f "$DEPLOY_KEY" ] && MOUNT_ARGS="$MOUNT_ARGS -v $DEPLOY_KEY:/home/\$USER/.ssh/deploy_keys/${deployKeyExpr}"

            # Build environment arguments
            ENV_ARGS=""
            ENV_ARGS="$ENV_ARGS -e BD_NO_DB=1"
            ENV_ARGS="$ENV_ARGS -e CLAUDE_CODE_OAUTH_TOKEN=''${CLAUDE_CODE_OAUTH_TOKEN:-}"
            ENV_ARGS="$ENV_ARGS -e HOST_UID=$(id -u)"
            ENV_ARGS="$ENV_ARGS -e HOST_USER=$USER"
            ENV_ARGS="$ENV_ARGS -e WRAPIX_PROMPT='${systemPrompt}'"

            # Generate unique container name
            CONTAINER_NAME="wrapix-$$"

            # Calculate resources (half of available CPUs, 4GB memory)
            CPUS=$(($(sysctl -n hw.ncpu) / 2))
            [ "$CPUS" -lt 2 ] && CPUS=2

            # Run container with automatic cleanup
            # Note: -w / overrides image's WorkingDir=/workspace which fails if mount isn't ready
            # The entrypoint script handles cd /workspace after mounts are available
            exec container run \
              --name "$CONTAINER_NAME" \
              --rm \
              -t -i \
              -w / \
              -c "$CPUS" \
              -m 4G \
              --network default \
              -v "$PROJECT_DIR:/workspace" \
              $MOUNT_ARGS \
              $ENV_ARGS \
              "''${WRAPIX_IMAGE:-$PROFILE_IMAGE}" \
              /entrypoint.sh
    '';
}
