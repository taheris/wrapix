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
read_only_source="$TEST_TMP/declared-read-only"
writable_source="$TEST_TMP/declared-writable"
host_sentinel="$TEST_TMP/undeclared-sibling-secret"
profile_config="$TEST_TMP/profile.json"
mkdir -p "$workspace"
printf 'workspace-content\n' >"$workspace/testfile.txt"
printf 'read-only-content\n' >"$read_only_source"
printf 'writable-content\n' >"$writable_source"
printf 'host-secret\n' >"$host_sentinel"

case "$(uname -s)" in
  Linux) IMAGE_REF="localhost/wrix-test-filesystem-isolation-$$:latest" ;;
  Darwin) IMAGE_REF="wrix-test-filesystem-isolation-$$:latest" ;;
  *) wrix_live_skip "unsupported live sandbox host: $(uname -s)" ;;
esac
wrix_write_profile_config "$profile_config" "$IMAGE_REF" "$image_source" direct
jq \
  --arg read_only_source "$read_only_source" \
  --arg writable_source "$writable_source" \
  '.profile.mounts = [
    {
      source: $read_only_source,
      dest: "/tmp/wrix-declared-read-only",
      mode: "ro",
      optional: false
    },
    {
      source: $writable_source,
      dest: "/tmp/wrix-declared-writable",
      mode: "rw",
      optional: false
    }
  ]' "$profile_config" >"$profile_config.tmp"
mv "$profile_config.tmp" "$profile_config"

# shellcheck disable=SC2016 # The in-container shell expands its positional arguments.
command=(
  "$launcher/bin/wrix" --profile-config "$profile_config" run "$workspace"
  /bin/bash -c '
    set -euo pipefail
    [[ "$(< /workspace/testfile.txt)" == "workspace-content" ]]
    [[ ! -e "$1" ]] || { printf "HOST-VISIBLE\n"; exit 91; }
    if find /mnt/wrix -type f -name "$2" -print -quit | grep -q .; then
      printf "SIBLING-VISIBLE\n"
      exit 92
    fi
    [[ "$(< /tmp/wrix-declared-read-only)" == "read-only-content" ]]
    # expected failure: a declared read-only mount must reject content writes.
    if printf "changed\n" >/tmp/wrix-declared-read-only 2>/dev/null; then
      printf "READ-ONLY-WRITABLE\n"
      exit 93
    fi
    [[ "$(< /tmp/wrix-declared-writable)" == "writable-content" ]]
    printf "updated-content\n" >/tmp/wrix-declared-writable
    grep -q "^wrix:" /etc/passwd
    printf "FILESYSTEM-ISOLATED\n"
  ' probe "$host_sentinel" "$(basename "$host_sentinel")"
)
printf -v command_line '%q ' "${command[@]}"
result=$(wrix_run_with_pty "$command_line")

[[ "$result" == *FILESYSTEM-ISOLATED* ]] || fail "launcher-backed probe did not complete: $result"
[[ "$result" != *HOST-VISIBLE* ]] || fail "launcher exposed host path outside declared mounts: $host_sentinel"
[[ "$result" != *SIBLING-VISIBLE* ]] || fail "launcher exposed an undeclared sibling through internal staging"
[[ "$result" != *READ-ONLY-WRITABLE* ]] || fail "read-only mount destination accepted a write"
[[ "$(<"$read_only_source")" == "read-only-content" ]] || fail "read-only source changed on the host"
[[ "$(<"$writable_source")" == "updated-content" ]] || fail "writable file changes did not sync to the selected host source"
[[ "$(<"$host_sentinel")" == "host-secret" ]] || fail "undeclared sibling changed on the host"
printf 'PASS: launcher mount plan exposes only workspace and declared mounts\n' >&2
