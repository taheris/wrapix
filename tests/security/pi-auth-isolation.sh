#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck source=tests/lib/live-sandbox.sh
source "$SCRIPT_DIR/../lib/live-sandbox.sh"

wrix_require_live_sandbox_darwin
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
WORKSPACE="$TEST_TMP/workspace"
HOME_DIR="$TEST_TMP/home"
AUTH_DIR="$TEST_TMP/pi"
AUTH_FILE="$AUTH_DIR/auth.json"
SIBLING_FILE="$AUTH_DIR/sibling-secret"
DEPLOY_KEY="$TEST_TMP/deploy-key"
OUT="$TEST_TMP/launcher.out"
ERR="$TEST_TMP/launcher.err"
mkdir -p "$WORKSPACE" "$HOME_DIR" "$AUTH_DIR"
printf '{"token":"selected-auth"}\n' >"$AUTH_FILE"
printf 'sibling-canary\n' >"$SIBLING_FILE"
chmod 600 "$AUTH_FILE" "$SIBLING_FILE"
wrix_make_ed25519_key "$DEPLOY_KEY" "pi-auth-isolation-test"
wrix_write_profile_config "$PROFILE_CONFIG" "$IMAGE_REF" "$IMAGE_SOURCE" pi
# shellcheck disable=SC2016
wrix_write_spawn_config "$SPAWN_CONFIG" "$WORKSPACE" bash -lc '
set -euo pipefail

[[ "${WRIX_PI_AUTH_JSON:-}" = "/mnt/wrix/pi-agent-auth/auth.json" ]]
[[ "$(jq -r .token "$WRIX_PI_AUTH_JSON")" = "selected-auth" ]]
[[ "$(find /mnt/wrix/pi-agent-auth -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]]
[[ ! -e /mnt/wrix/pi-agent-auth/sibling-secret ]]
if grep -R -qF sibling-canary /mnt/wrix/pi-agent-auth; then
  printf "Pi auth staging exposed a sibling credential file\n" >&2
  exit 1
fi
printf "{\"token\":\"updated-auth\"}\n" >"$WRIX_PI_AUTH_JSON"
'

if ! HOME="$HOME_DIR" WRIX_DEPLOY_KEY="$DEPLOY_KEY" WRIX_GIT_SIGN=0 \
  WRIX_PI_AUTH_FILE="$AUTH_FILE" \
  wrix_run_spawn "$LAUNCHER" "$PROFILE_CONFIG" "$SPAWN_CONFIG" >"$OUT" 2>"$ERR"; then
  sed 's/^/  /' "$ERR" >&2
  fail "Darwin Pi auth isolation launch failed"
fi

if [[ "$(jq -r .token "$AUTH_FILE")" != "updated-auth" ]]; then
  fail "updated Pi auth was not synchronized to the selected host file"
fi
if [[ "$(cat "$SIBLING_FILE")" != "sibling-canary" ]]; then
  fail "Pi auth synchronization modified a sibling host file"
fi

printf 'PASS: Darwin Pi auth exposes and synchronizes only the selected file\n'
