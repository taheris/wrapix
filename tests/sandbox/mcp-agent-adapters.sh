#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
export REPO_ROOT

fail() {
  local message="$1"
  printf 'FAIL: %s\n' "$message" >&2
  exit 1
}

for command_name in jq nix; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name not on PATH"
done

manifests=$(nix eval --impure --no-warn-dirty --json --expr "
  let
    flake = builtins.getFlake \"git+file://$REPO_ROOT\";
    system = builtins.currentSystem;
    lib = flake.legacyPackages.\${system}.lib;
    manifestFor = agent:
      let
        sandbox = lib.mkSandbox {
          profile = lib.profiles.base;
          inherit agent;
          mcp.tmux = {
            audit = \"/workspace/audit.jsonl\";
          };
        };
      in
        builtins.fromJSON (builtins.readFile sandbox.image.mcpAvailableJson);
  in
    map manifestFor [ \"direct\" \"claude\" \"pi\" ]
")

if ! jq -e '
  length == 3
  and .[0] == .[1]
  and .[1] == .[2]
  and .[0].schema == 1
  and .[0].runtime_selection == false
  and .[0].servers == [
    {
      name: "tmux",
      command: "tmux-mcp",
      args: [],
      env: { TMUX_DEBUG_AUDIT: "/workspace/audit.jsonl" }
    }
  ]
' <<<"$manifests" >/dev/null; then
  fail "Nix generated different MCP registry manifests across agents: $manifests"
fi

bash "$REPO_ROOT/tests/sandbox/entrypoint-contract.sh" \
  test_runtime_mcp_registration_uses_claude_user_config_both_entrypoints
bash "$REPO_ROOT/tests/sandbox/pi-mcp-extension.sh"

printf 'PASS: MCP registry, runtime selection, and agent adapters share one manifest\n' >&2
