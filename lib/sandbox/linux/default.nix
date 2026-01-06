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
in
{
  mkSandbox = { profile, profileImage, entrypoint }:
    pkgs.writeShellScriptBin "wrapix" ''
  set -euo pipefail

  PROJECT_DIR="''${1:-$(pwd)}"

  WRAPIX_PROMPT='${systemPrompt}'
  exec podman run --rm -it \
    --network=pasta \
    --userns=keep-id \
    --entrypoint /bin/bash \
    -v "$PROJECT_DIR:/workspace:rw" \
    -v "$HOME/.claude:/home/$USER/.claude:rw" \
    -v "$HOME/.claude.json:/home/$USER/.claude.json:rw" \
    -v "$HOME/.config/git:/home/$USER/.config/git:ro" \
    -e "ANTHROPIC_API_KEY=''${ANTHROPIC_API_KEY:-}" \
    -e "WRAPIX_PROMPT=$WRAPIX_PROMPT" \
    -w /workspace \
    docker-archive:${profileImage} \
    -c 'claude --dangerously-skip-permissions --append-system-prompt "$WRAPIX_PROMPT"'
  '';
}
