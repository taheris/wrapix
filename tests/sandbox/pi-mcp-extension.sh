#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TEST_TMP="$(mktemp -d -t wrix-pi-mcp.XXXXXX)"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  local message="$1"
  printf 'FAIL: %s\n' "$message" >&2
  exit 1
}

for command_name in jq nix pi timeout; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name not on PATH"
done

NODE_DIR=$(nix build --no-link --print-out-paths --no-warn-dirty "$REPO_ROOT#nodejs")
NODE_BIN="$NODE_DIR/bin/node"
TMUX_MCP_DIR=$(nix build --no-link --print-out-paths --no-warn-dirty "$REPO_ROOT#tmux-mcp")
TMUX_MCP_BIN="$TMUX_MCP_DIR/bin/tmux-mcp"
EXTENSION="$REPO_ROOT/lib/sandbox/pi-mcp-extension.ts"
SERVER="$REPO_ROOT/tests/sandbox/fixtures/mcp-server.mjs"

if ! "$NODE_BIN" "$REPO_ROOT/tests/sandbox/pi-mcp-client.mjs" \
  "$EXTENSION" "$SERVER" "$TMUX_MCP_BIN"; then
  fail "Pi MCP stdio client did not complete initialize/list/call"
fi

MANIFEST="$TEST_TMP/manifest.json"
PROBE="$TEST_TMP/probe.ts"
PROBE_OUTPUT="$TEST_TMP/tools.json"
PI_OUTPUT="$TEST_TMP/pi.jsonl"
PI_ERROR="$TEST_TMP/pi.stderr"
mkdir -p "$TEST_TMP/home/.pi/agent/extensions"
cp "$EXTENSION" "$TEST_TMP/home/.pi/agent/extensions/wrix-mcp.ts"

jq -n \
  --arg command "$NODE_BIN" \
  --arg server "$SERVER" \
  '{
    schema: 1,
    servers: [
      {
        name: "test",
        command: $command,
        args: [$server],
        env: { WRIX_MCP_TEST_ENV: "manifest-env" }
      }
    ]
  }' >"$MANIFEST"

cat >"$PROBE" <<'EOF'
import { writeFileSync } from "node:fs";

export default function probe(pi) {
  pi.on("session_start", () => {
    const tools = pi.getAllTools().map((tool) => ({
      name: tool.name,
      parameters: tool.parameters,
    }));
    writeFileSync(process.env.WRIX_MCP_PROBE_OUTPUT, JSON.stringify(tools));
  });
}
EOF
cp "$PROBE" "$TEST_TMP/home/.pi/agent/extensions/z-probe.ts"

if ! printf '%s\n' '{"type":"get_state"}' | env \
  HOME="$TEST_TMP/home" \
  PI_OFFLINE=1 \
  PI_SKIP_VERSION_CHECK=1 \
  WRIX_MCP_MANIFEST="$MANIFEST" \
  WRIX_MCP_PROBE_OUTPUT="$PROBE_OUTPUT" \
  timeout 20 pi \
    --mode rpc \
    --no-session \
    --no-builtin-tools \
    --no-context-files \
    --no-skills \
    --no-prompt-templates \
    --no-themes \
    >"$PI_OUTPUT" 2>"$PI_ERROR"; then
  fail "Pi did not load the Wrix MCP extension: $(<"$PI_ERROR")"
fi

if grep -q '"type":"extension_error"' "$PI_OUTPUT"; then
  fail "Pi reported an extension error: $(<"$PI_OUTPUT")"
fi
if [[ ! -f "$PROBE_OUTPUT" ]]; then
  fail "Pi MCP tool probe was not written"
fi
if ! jq -e '
  any(.[];
    .name == "wrix_test_echo"
    and .parameters.type == "object"
    and .parameters.properties.text.type == "string"
  )
' "$PROBE_OUTPUT" >/dev/null; then
  fail "Pi did not register the MCP tool schema: $(<"$PROBE_OUTPUT")"
fi

printf 'PASS: Pi loads the Wrix extension and registers tools from the MCP manifest\n' >&2
