# Linux sandbox implementation using Podman pod orchestration
#
# Creates a 3-container pod:
# 1. Init container (NET_ADMIN cap, sets iptables, exits)
# 2. Squid sidecar (runs continuously, filters traffic)
# 3. Claude container (unprivileged, interactive)

{ pkgs, initImage }:

{
  mkSandbox = { profile, profileImage, entrypoint }:
    pkgs.writeShellScriptBin "wrapix" ''
  set -euo pipefail

  PROJECT_DIR="''${1:-$(pwd)}"
  POD_NAME="wrapix-$$"

  cleanup() {
    podman pod rm -f "$POD_NAME" 2>/dev/null || true
  }
  trap cleanup EXIT SIGINT SIGTERM

  # Create pod with isolated network
  podman pod create --name "$POD_NAME" --network=slirp4netns

  # Init container: set up iptables, exit
  podman run --rm --pod "$POD_NAME" --cap-add=NET_ADMIN ${initImage}

  # Squid sidecar: blocklist filtering
  podman run --detach --pod "$POD_NAME" --name "''${POD_NAME}-squid" \
    ${profileImage} squid -f /etc/squid/squid.conf -N

  # Wait for Squid to be ready
  for i in {1..50}; do
    podman exec "''${POD_NAME}-squid" squid -k check 2>/dev/null && break
    sleep 0.1
  done

  # Claude container: completely unprivileged
  exec podman run --rm -it --pod "$POD_NAME" --userns=keep-id \
    -v "$PROJECT_DIR:/workspace:rw" \
    -v "$HOME/.claude:/home/$USER/.claude:rw" \
    -v "$HOME/.claude.json:/home/$USER/.claude.json:rw" \
    -v "$HOME/.config/git:/home/$USER/.config/git:ro" \
    -e "ANTHROPIC_API_KEY=''${ANTHROPIC_API_KEY:-}" \
    ${profileImage} ${entrypoint}/bin/wrapix-entrypoint
  '';
}
