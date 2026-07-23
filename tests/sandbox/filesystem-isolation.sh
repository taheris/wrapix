#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck source=tests/lib/live-sandbox.sh
source "$SCRIPT_DIR/../lib/live-sandbox.sh"

TEST_TMP="$(mktemp -d -t wrix-fs-isolation.XXXXXX)"
IMAGE_REF=""

cleanup() {
  if [[ -n "$IMAGE_REF" ]]; then
    wrix_remove_image_ref "$IMAGE_REF" >/dev/null 2>&1 || true # best-effort: cleanup must not mask the verifier result.
  fi
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  local message="$1"
  printf 'FAIL: %s\n' "$message" >&2
  exit 1
}

wrix_require_live_sandbox
cd "$REPO_ROOT"

launcher=$(wrix_build_live_launcher)
image_source=$(wrix_realize_test_image_source direct)
workspace="$TEST_TMP/workspace"
host_sentinel="$TEST_TMP/host-secret"
profile_config="$TEST_TMP/profile.json"
mkdir -p "$workspace"
printf 'workspace-content\n' >"$workspace/testfile.txt"
printf 'host-secret\n' >"$host_sentinel"

case "$(uname -s)" in
  Linux) IMAGE_REF="localhost/wrix-test-filesystem-isolation-$$:latest" ;;
  Darwin) IMAGE_REF="wrix-test-filesystem-isolation-$$:latest" ;;
  *) wrix_live_skip "unsupported live sandbox host: $(uname -s)" ;;
esac
wrix_write_profile_config "$profile_config" "$IMAGE_REF" "$image_source" direct

# shellcheck disable=SC2016 # The in-container shell expands its positional argument.
command=(
  "$launcher/bin/wrix" --profile-config "$profile_config" run "$workspace"
  /bin/bash -c '
    set -euo pipefail
    [[ "$(< /workspace/testfile.txt)" == "workspace-content" ]]
    [[ ! -e "$1" ]] || { printf "HOST-VISIBLE\n"; exit 91; }
    grep -q "^wrix:" /etc/passwd
    printf "FILESYSTEM-ISOLATED\n"
  ' probe "$host_sentinel"
)
printf -v command_line '%q ' "${command[@]}"
result=$(wrix_run_with_pty "$command_line")

[[ "$result" == *FILESYSTEM-ISOLATED* ]] || fail "launcher-backed probe did not complete: $result"
[[ "$result" != *HOST-VISIBLE* ]] || fail "launcher exposed host path outside declared mounts: $host_sentinel"
printf 'PASS: launcher mount plan exposes only workspace and declared mounts\n' >&2
