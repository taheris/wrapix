#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck source=tests/lib/live-sandbox.sh
source "$SCRIPT_DIR/../lib/live-sandbox.sh"

wrix_require_live_sandbox
cd "$REPO_ROOT"

TEST_TMP=$(mktemp -d -t wrix-pi-auth-isolation.XXXXXX)
IMAGE_REF=""
cleanup() {
  rm -rf "$TEST_TMP"
  wrix_remove_image_ref "$IMAGE_REF"
}
trap cleanup EXIT

fail() {
  local message="$1"
  printf 'FAIL: %s\n' "$message" >&2
  exit 1
}

LAUNCHER=$(wrix_build_live_launcher)
IMAGE_SOURCE=$(wrix_realize_test_image_source pi)
IMAGE_REF=$(wrix_live_image_ref "pi-auth-isolation-$$")
PROFILE_CONFIG="$TEST_TMP/profile.json"
SPAWN_CONFIG="$TEST_TMP/spawn.json"
SYMLINK_CONFIG="$TEST_TMP/spawn-symlink.json"
WORKSPACE="$TEST_TMP/workspace"
HOME_DIR="$TEST_TMP/home"
AUTH_DIR="$TEST_TMP/pi"
AUTH_FILE="$AUTH_DIR/auth.json"
SIBLING_FILE="$AUTH_DIR/sibling-secret"
SYMLINK_TARGET="$TEST_TMP/symlink-target"
DEPLOY_KEY="$TEST_TMP/deploy-key"
OUT="$TEST_TMP/launcher.out"
ERR="$TEST_TMP/launcher.err"
SYMLINK_OUT="$TEST_TMP/symlink.out"
SYMLINK_ERR="$TEST_TMP/symlink.err"
PLATFORM=$(uname -s)
case "$PLATFORM" in
  Linux) CONTAINER_AUTH_FILE="/mnt/wrix/file/pi-auth.json" ;;
  Darwin) CONTAINER_AUTH_FILE="/mnt/wrix/pi-agent-auth/auth.json" ;;
  *) fail "unsupported platform: $PLATFORM" ;;
esac
mkdir -p "$WORKSPACE" "$HOME_DIR" "$AUTH_DIR"
printf '{"token":"selected-auth"}\n' >"$AUTH_FILE"
printf 'sibling-canary\n' >"$SIBLING_FILE"
printf 'symlink-target-canary\n' >"$SYMLINK_TARGET"
chmod 600 "$AUTH_FILE" "$SIBLING_FILE" "$SYMLINK_TARGET"
wrix_make_ed25519_key "$DEPLOY_KEY" "pi-auth-isolation-test"
wrix_write_profile_config "$PROFILE_CONFIG" "$IMAGE_REF" "$IMAGE_SOURCE" pi
# shellcheck disable=SC2016
wrix_write_spawn_config "$SPAWN_CONFIG" "$WORKSPACE" bash -lc '
set -euo pipefail

auth_dir=$(dirname "$WRIX_PI_AUTH_JSON")
[[ "${WRIX_PI_AUTH_JSON:-}" = "${WRIX_TEST_AUTH_FILE:?}" ]]
[[ "$(jq -r .token "$WRIX_PI_AUTH_JSON")" = "selected-auth" ]]
[[ "$(find "$auth_dir" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]]
[[ ! -e "$auth_dir/sibling-secret" ]]
if grep -R -qF sibling-canary "$auth_dir"; then
  printf "Pi auth delivery exposed a sibling credential file\n" >&2
  exit 1
fi
printf "{\"token\":\"updated-auth\"}\n" >"$WRIX_PI_AUTH_JSON"
'
jq --arg path "$CONTAINER_AUTH_FILE" '.env += [["WRIX_TEST_AUTH_FILE", $path]]' \
  "$SPAWN_CONFIG" >"$SPAWN_CONFIG.tmp"
mv "$SPAWN_CONFIG.tmp" "$SPAWN_CONFIG"

if ! HOME="$HOME_DIR" WRIX_DEPLOY_KEY="$DEPLOY_KEY" WRIX_GIT_SIGN=0 \
  WRIX_PI_AUTH_FILE="$AUTH_FILE" \
  wrix_run_spawn "$LAUNCHER" "$PROFILE_CONFIG" "$SPAWN_CONFIG" >"$OUT" 2>"$ERR"; then
  sed 's/^/  /' "$ERR" >&2
  fail "$PLATFORM Pi auth isolation launch failed"
fi

if [[ "$(jq -r .token "$AUTH_FILE")" != "updated-auth" ]]; then
  fail "updated Pi auth was not synchronized to the selected host file"
fi
if [[ "$(cat "$SIBLING_FILE")" != "sibling-canary" ]]; then
  fail "Pi auth synchronization modified a sibling host file"
fi

if [[ "$PLATFORM" = "Darwin" ]]; then
  # shellcheck disable=SC2016
  wrix_write_spawn_config "$SYMLINK_CONFIG" "$WORKSPACE" bash -lc '
set -euo pipefail

rm -f "$WRIX_PI_AUTH_JSON"
ln -s "${WRIX_TEST_SYNC_TARGET:?}" "$WRIX_PI_AUTH_JSON"
'
  jq --arg target "$SYMLINK_TARGET" '.env += [["WRIX_TEST_SYNC_TARGET", $target]]' \
    "$SYMLINK_CONFIG" >"$SYMLINK_CONFIG.tmp"
  mv "$SYMLINK_CONFIG.tmp" "$SYMLINK_CONFIG"
  if HOME="$HOME_DIR" WRIX_DEPLOY_KEY="$DEPLOY_KEY" WRIX_GIT_SIGN=0 \
    WRIX_PI_AUTH_FILE="$AUTH_FILE" \
    wrix_run_spawn "$LAUNCHER" "$PROFILE_CONFIG" "$SYMLINK_CONFIG" \
      >"$SYMLINK_OUT" 2>"$SYMLINK_ERR"; then
    fail "Darwin Pi auth synchronization followed a guest-controlled symlink"
  fi
  if ! grep -qF "not a regular file" "$SYMLINK_ERR"; then
    sed 's/^/  /' "$SYMLINK_ERR" >&2
    fail "Darwin Pi auth symlink rejection was not actionable"
  fi
  if [[ "$(cat "$SYMLINK_TARGET")" != "symlink-target-canary" ]]; then
    fail "Darwin Pi auth synchronization modified the symlink target"
  fi
fi

printf 'PASS: %s Pi auth exposes and synchronizes only the selected file\n' "$PLATFORM"
