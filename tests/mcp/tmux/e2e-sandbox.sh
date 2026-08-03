#!/usr/bin/env bash
# Verifier for tmux-mcp's mkSandbox composition (specs/tmux-mcp.md).
#
# Builds an explicit `mcp.tmux` rust sandbox and executes tmux-mcp from that
# image's OCI configuration and Nix-store layers. A host runtime uses Podman;
# a nested sandbox uses fresh user, mount, and PID namespaces over the same
# immutable layer content without copying the multi-gigabyte Nix closure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
# shellcheck source=tests/lib/podman-image.sh
source "$REPO_ROOT/tests/lib/podman-image.sh"

fail() {
  local message="$1"
  printf 'FAIL: %s\n' "$message" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "$command_name not on PATH"
  fi
}

verify_initialize_response() {
  local label="$1"
  local result="$2"
  local tmux_path="$3"
  local tmux_mcp_path="$4"

  if [[ "$result" != *"$tmux_path"* || "$result" != *"$tmux_mcp_path"* ]]; then
    fail "$label did not resolve tmux and tmux-mcp from the image PATH: $result"
  fi
  if [[ "$result" != *'"serverInfo"'* || "$result" != *'"tmux-mcp"'* ]]; then
    fail "$label did not receive a tmux-mcp initialize response: $result"
  fi
}

image_layer_contains() {
  local image_layout="$1"
  local manifest_path="$2"
  local expected_path="$3"
  local layers=()
  local index
  local digest

  mapfile -t layers < <(jq -r '.layers[].digest | sub("^sha256:"; "")' "$manifest_path")
  for ((index = ${#layers[@]} - 1; index >= 0; index--)); do
    digest="${layers[$index]}"
    if tar --list --file "$image_layout/blobs/sha256/$digest" "$expected_path" >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

initialize_request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"wrix-verifier","version":"1.0"}}}'

uname_s="$(uname -s)"
[[ "$uname_s" == "Linux" ]] || fail "Linux-only verifier (uname=$uname_s)"
require_command nix
require_command tar

NESTED_CONTAINER=0
if [[ -e /run/.containerenv ]]; then
  NESTED_CONTAINER=1
  require_command chroot
  require_command mount
  require_command unshare
else
  require_command podman
  require_command skopeo
fi

PODMAN_COMMAND=()
if [[ "$NESTED_CONTAINER" -eq 0 ]]; then
  PODMAN_COMMAND=("$(command -v podman)")
fi
SKOPEO_BIN=""
if [[ "$NESTED_CONTAINER" -eq 0 ]]; then
  SKOPEO_BIN="$(command -v skopeo)"
fi
MCP_HEALTH_TIMEOUT=20
build_log="$(mktemp -t wrix-e2e-sandbox-build.XXXXXX)"
CONTAINER_NAME="wrix-test-tmux-e2e-sandbox-$$"
IMAGE_REF=""
NAMESPACE_ROOT=""

podman() {
  "${PODMAN_COMMAND[@]}" "$@"
}

skopeo() {
  "$SKOPEO_BIN" "$@"
}

cleanup() {
  local status="$?"
  trap - EXIT
  rm -f "$build_log"
  if [[ -n "$IMAGE_REF" ]] && podman container exists "$CONTAINER_NAME"; then
    if ! podman rm --force "$CONTAINER_NAME" >/dev/null; then
      printf 'WARN: could not remove test container %s\n' "$CONTAINER_NAME" >&2
    fi
  fi
  if [[ -n "$IMAGE_REF" ]] && podman image exists "$IMAGE_REF"; then
    if ! podman rmi "$IMAGE_REF" >/dev/null; then
      printf 'WARN: could not remove test image %s\n' "$IMAGE_REF" >&2
    fi
  fi
  if [[ -n "$NAMESPACE_ROOT" ]]; then
    rm -rf "$NAMESPACE_ROOT"
  fi
  exit "$status"
}
trap cleanup EXIT

verify_podman_image_mcp_health() {
  local image_path="$1"
  local tmux_path="$2"
  local tmux_mcp_path="$3"
  local result

  if ! result=$(printf '%s\n' "$initialize_request" | timeout "$MCP_HEALTH_TIMEOUT" \
    "${PODMAN_COMMAND[@]}" run --rm -i --network=none --entrypoint bash \
    --name "$CONTAINER_NAME" "$IMAGE_REF" -c \
    'command -v tmux; command -v tmux-mcp; exec tmux-mcp' 2>&1); then
    fail "Podman image MCP initialize failed: $result"
  fi

  verify_initialize_response "Podman image" "$result" "$tmux_path" "$tmux_mcp_path"
  [[ "$image_path" == *"/nix/store/"* ]] || fail "image PATH does not use its Nix-store closure"
}

verify_namespaced_image_mcp_health() {
  local image_source="$1"
  local image_layout
  local manifest_digest
  local manifest_path
  local config_digest
  local config_path
  local image_path
  local bash_path
  local tmux_path
  local tmux_mcp_path
  local result

  image_layout=$(jq -er '.oci_layout | strings | select(length > 0)' "$image_source")
  manifest_digest=$(jq -er '.manifests[0].digest | sub("^sha256:"; "")' "$image_layout/index.json")
  manifest_path="$image_layout/blobs/sha256/$manifest_digest"
  config_digest=$(jq -er '.config.digest | sub("^sha256:"; "")' "$manifest_path")
  config_path="$image_layout/blobs/sha256/$config_digest"
  image_path=$(jq -er '.config.Env[] | select(startswith("PATH=")) | sub("^PATH="; "")' "$config_path")
  bash_path=$(PATH="$image_path" command -v bash) || fail "bash does not resolve from image PATH"
  tmux_path=$(PATH="$image_path" command -v tmux) || fail "tmux does not resolve from image PATH"
  tmux_mcp_path=$(PATH="$image_path" command -v tmux-mcp) || fail "tmux-mcp does not resolve from image PATH"

  image_layer_contains "$image_layout" "$manifest_path" "$tmux_path" \
    || fail "tmux PATH entry is absent from the built image layers"
  image_layer_contains "$image_layout" "$manifest_path" "$tmux_mcp_path" \
    || fail "tmux-mcp PATH entry is absent from the built image layers"

  NAMESPACE_ROOT=$(mktemp -d -t wrix-tmux-mcp-rootfs.XXXXXX)
  mkdir -p "$NAMESPACE_ROOT/nix/store" "$NAMESPACE_ROOT/tmp"
  chmod 1777 "$NAMESPACE_ROOT/tmp"

  # shellcheck disable=SC2016  # The nested shell expands its positional parameters.
  if ! result=$(printf '%s\n' "$initialize_request" | timeout "$MCP_HEALTH_TIMEOUT" \
    unshare --user --map-root-user --mount --pid --fork bash -c '
      set -euo pipefail
      rootfs="$1"
      image_path="$2"
      bash_path="$3"
      mount --bind /nix/store "$rootfs/nix/store"
      mount --options remount,bind,ro "$rootfs/nix/store"
      exec env -i PATH="$image_path" TMPDIR=/tmp chroot "$rootfs" "$bash_path" -c \
        "command -v tmux; command -v tmux-mcp; exec tmux-mcp"
    ' _ "$NAMESPACE_ROOT" "$image_path" "$bash_path" 2>&1); then
    fail "namespaced image MCP initialize failed: $result"
  fi

  verify_initialize_response "Namespaced image" "$result" "$tmux_path" "$tmux_mcp_path"
}

cd "$REPO_ROOT"

if ! PACKAGE_PATH=$(nix build --no-link --print-out-paths --no-warn-dirty --impure --expr "
  let
    flake = builtins.getFlake \"git+file://$REPO_ROOT\";
    system = builtins.currentSystem;
    lib = flake.legacyPackages.\${system}.lib;
  in
    (lib.mkSandbox {
      profile = lib.profiles.rust;
      mcp.tmux = { };
    }).package
" 2>"$build_log"); then
  cat "$build_log" >&2
  fail "nix build explicit mkSandbox mcp.tmux sandbox"
fi
PROFILE_CONFIG=$(grep -oE -- '--profile-config[[:space:]]+[^[:space:]]+' "$PACKAGE_PATH/bin/wrix" | awk '{print $2}' | head -1)
IMAGE_SOURCE=$(jq -r '.image.source' "$PROFILE_CONFIG")
WRAPPER_IMAGE_REF=$(jq -r '.image.ref' "$PROFILE_CONFIG")
SELECTED_AGENT=$(jq -r '.agent.kind' "$PROFILE_CONFIG")

[[ "$SELECTED_AGENT" == "direct" ]] || fail "explicit mcp.tmux sandbox did not preserve the default direct agent"
[[ -n "$IMAGE_SOURCE" && -e "$IMAGE_SOURCE" ]] || fail "could not extract image.source from $PROFILE_CONFIG"
[[ -n "$WRAPPER_IMAGE_REF" ]] || fail "could not extract image.ref from $PROFILE_CONFIG"

if ! AUDIT_CONFIG=$(nix build --no-link --print-out-paths --no-warn-dirty --impure --expr "
  let
    flake = builtins.getFlake \"git+file://$REPO_ROOT\";
    system = builtins.currentSystem;
    lib = flake.legacyPackages.\${system}.lib;
  in
    (lib.mkSandbox {
      profile = lib.profiles.rust;
      mcp.tmux = {
        audit = \"/workspace/.debug-audit.log\";
        auditFull = \"/workspace/.debug-audit\";
      };
    }).image.mcpAvailableJson
" 2>>"$build_log"); then
  cat "$build_log" >&2
  fail "nix build explicit mkSandbox mcp.tmux diagnostic settings"
fi

if ! jq -e '
  .servers[0].name == "tmux"
  and .servers[0].command == "tmux-mcp"
  and .servers[0].env.TMUX_DEBUG_AUDIT == "/workspace/.debug-audit.log"
  and .servers[0].env.TMUX_DEBUG_AUDIT_FULL == "/workspace/.debug-audit"
' "$AUDIT_CONFIG" >/dev/null; then
  cat "$AUDIT_CONFIG" >&2
  fail "mcp.tmux audit/auditFull settings not present in the MCP manifest"
fi

IMAGE_LAYOUT=$(jq -er '.oci_layout' "$IMAGE_SOURCE")
MANIFEST_DIGEST=$(jq -er '.manifests[0].digest | sub("^sha256:"; "")' "$IMAGE_LAYOUT/index.json")
CONFIG_DIGEST=$(jq -er '.config.digest | sub("^sha256:"; "")' "$IMAGE_LAYOUT/blobs/sha256/$MANIFEST_DIGEST")
IMAGE_PATH=$(jq -er '.config.Env[] | select(startswith("PATH=")) | sub("^PATH="; "")' "$IMAGE_LAYOUT/blobs/sha256/$CONFIG_DIGEST")
TMUX_PATH=$(PATH="$IMAGE_PATH" command -v tmux) || fail "tmux does not resolve from image PATH"
TMUX_MCP_PATH=$(PATH="$IMAGE_PATH" command -v tmux-mcp) || fail "tmux-mcp does not resolve from image PATH"

if [[ "$NESTED_CONTAINER" -eq 1 ]]; then
  verify_namespaced_image_mcp_health "$IMAGE_SOURCE"
else
  IMAGE_REF=$(wrix_unique_image_ref "wrix-test-tmux-e2e-sandbox")
  wrix_load_test_image "$IMAGE_SOURCE" "$(wrix_image_short_name "$WRAPPER_IMAGE_REF")" "$IMAGE_REF"
  verify_podman_image_mcp_health "$IMAGE_PATH" "$TMUX_PATH" "$TMUX_MCP_PATH"
fi

echo "PASS: explicit tmux-mcp rust sandbox executed the built image's MCP server" >&2
