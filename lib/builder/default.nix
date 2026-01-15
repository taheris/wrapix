# wrapix-builder: CLI wrapper for persistent Linux remote builder
#
# Manages a persistent container that serves as an ssh-ng:// remote builder
# for Nix on macOS. Uses Apple's container CLI (macOS 26+).
#
# Usage:
#   wrapix-builder start   - Start the builder container
#   wrapix-builder stop    - Stop and remove the container
#   wrapix-builder status  - Show builder status
#   wrapix-builder ssh     - Connect to builder via SSH
#   wrapix-builder config  - Print nix.conf snippet for remote builder
#
{ pkgs, linuxPkgs }:

let
  builderImage = import ../sandbox/builder/image.nix {
    pkgs = linuxPkgs;
  };

in
pkgs.writeShellScriptBin "wrapix-builder" ''
  set -euo pipefail

  # XDG-compliant directories
  XDG_DATA_HOME="''${XDG_DATA_HOME:-$HOME/.local/share}"
  XDG_CACHE_HOME="''${XDG_CACHE_HOME:-$HOME/.cache}"
  WRAPIX_DATA="$XDG_DATA_HOME/wrapix"
  WRAPIX_CACHE="$XDG_CACHE_HOME/wrapix"

  # Builder-specific paths
  KEYS_DIR="$WRAPIX_DATA/builder-keys"
  NIX_STORE="$WRAPIX_DATA/builder-nix"
  CONTAINER_NAME="wrapix-builder"
  BUILDER_IMAGE="wrapix-builder:latest"
  SSH_PORT=2222

  usage() {
    echo "Usage: wrapix-builder <command>"
    echo ""
    echo "Commands:"
    echo "  start   - Start the builder container"
    echo "  stop    - Stop and remove the container"
    echo "  status  - Show builder status and SSH connection info"
    echo "  ssh     - Connect to builder via SSH"
    echo "  config  - Print nix.conf configuration for remote builder"
    exit 1
  }

  check_macos_version() {
    if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
      echo "Error: macOS 26+ required (current: $(sw_vers -productVersion))"
      exit 1
    fi
  }

  ensure_container_system() {
    if ! container system status >/dev/null 2>&1; then
      echo "Starting container system..."
      container system start
      sleep 2
    fi
  }

  generate_ssh_keys() {
    mkdir -p "$KEYS_DIR"
    if [ ! -f "$KEYS_DIR/builder_ed25519" ]; then
      echo "Generating SSH keys..."
      ssh-keygen -t ed25519 -f "$KEYS_DIR/builder_ed25519" -N "" -C "wrapix-builder"
    fi
  }

  load_builder_image() {
    IMAGE_VERSION_FILE="$WRAPIX_DATA/images/wrapix-builder.version"
    CURRENT_IMAGE_HASH="${builderImage}"
    mkdir -p "$WRAPIX_DATA/images"

    if ! container image inspect "$BUILDER_IMAGE" >/dev/null 2>&1 || \
       [ ! -f "$IMAGE_VERSION_FILE" ] || [ "$(cat "$IMAGE_VERSION_FILE")" != "$CURRENT_IMAGE_HASH" ]; then
      echo "Loading builder image..."
      # Delete old image if exists
      container image delete "$BUILDER_IMAGE" 2>/dev/null || true
      # Convert Docker-format tar to OCI-archive format
      OCI_TAR="$WRAPIX_CACHE/builder-image-oci.tar"
      mkdir -p "$WRAPIX_CACHE"
      ${pkgs.skopeo}/bin/skopeo --insecure-policy copy "docker-archive:${builderImage}" "oci-archive:$OCI_TAR"
      # Load and capture the digest from output
      LOAD_OUTPUT=$(container image load --input "$OCI_TAR" 2>&1)
      LOADED_REF=$(echo "$LOAD_OUTPUT" | grep -oE 'untagged@sha256:[a-f0-9]+' | head -1)
      if [ -n "$LOADED_REF" ]; then
        container image tag "$LOADED_REF" "$BUILDER_IMAGE"
      fi
      rm -f "$OCI_TAR"
      echo "$CURRENT_IMAGE_HASH" > "$IMAGE_VERSION_FILE"
    fi
  }

  cmd_start() {
    check_macos_version
    ensure_container_system

    # Check if already running
    if container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
      echo "Builder container is already running"
      echo "Use 'wrapix-builder ssh' to connect"
      exit 0
    fi

    generate_ssh_keys
    load_builder_image

    # Initialize persistent nix store directory
    mkdir -p "$NIX_STORE"

    echo "Starting builder container..."

    # Run container (persistent, no --rm)
    container run \
      --name "$CONTAINER_NAME" \
      -d \
      -c 4 \
      -m 4096M \
      --network default \
      -p "$SSH_PORT:22" \
      -v "$NIX_STORE:/nix" \
      -v "$KEYS_DIR:/run/keys:ro" \
      "$BUILDER_IMAGE" \
      /entrypoint.sh

    echo ""
    echo "Builder started successfully!"
    echo ""
    echo "Connect via: wrapix-builder ssh"
    echo "Or configure Nix: wrapix-builder config"
  }

  cmd_stop() {
    echo "Stopping builder container..."
    container stop "$CONTAINER_NAME" 2>/dev/null || true
    container rm "$CONTAINER_NAME" 2>/dev/null || true
    echo "Builder stopped"
  }

  cmd_status() {
    if container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
      echo "Builder: running"
      echo ""
      echo "SSH connection:"
      echo "  ssh -p $SSH_PORT -i $KEYS_DIR/builder_ed25519 builder@localhost"
      echo ""
      echo "Nix store: $NIX_STORE"
      echo "SSH keys:  $KEYS_DIR"
    else
      echo "Builder: stopped"
      echo ""
      echo "Run 'wrapix-builder start' to start the builder"
    fi
  }

  cmd_ssh() {
    if ! container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
      echo "Error: Builder is not running"
      echo "Run 'wrapix-builder start' first"
      exit 1
    fi

    exec ssh -p "$SSH_PORT" \
      -i "$KEYS_DIR/builder_ed25519" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      builder@localhost
  }

  cmd_config() {
    echo "# Add to /etc/nix/nix.conf or ~/.config/nix/nix.conf:"
    echo ""
    echo "builders = ssh-ng://builder@localhost?ssh-key=$KEYS_DIR/builder_ed25519 aarch64-linux - 4 1 big-parallel,benchmark"
    echo ""
    echo "# Or for builders file format (/etc/nix/machines):"
    echo "# builder@localhost aarch64-linux $KEYS_DIR/builder_ed25519 4 1 big-parallel,benchmark"
  }

  # Main command dispatch
  case "''${1:-}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    ssh)    cmd_ssh ;;
    config) cmd_config ;;
    *)      usage ;;
  esac
''
