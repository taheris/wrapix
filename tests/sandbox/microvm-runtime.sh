#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# shellcheck source=tests/lib/live-sandbox.sh
source "$SCRIPT_DIR/../lib/live-sandbox.sh"

TEST_TMP="$(mktemp -d -t wrix-microvm-runtime.XXXXXX)"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  local message="$1"
  printf 'FAIL: %s\n' "$message" >&2
  return 1
}

test_linux_microvm_runtime() {
  local command_line output sandbox workspace
  local -a command
  wrix_require_live_sandbox_linux
  [[ -e /dev/kvm ]] || wrix_live_skip "KVM device is required for the live microVM verifier"
  cd "$REPO_ROOT"

  sandbox=$(wrix_build_packaged_live_sandbox)
  workspace="$TEST_TMP/workspace"
  mkdir -p "$workspace"

  cat >"$workspace/assert-microvm.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail

[[ -x /krun-relay ]]
[[ -x /krun-init.sh ]]
[[ -f /lib/libfakeuid.so ]]
[[ "${LD_PRELOAD:-}" == "/lib/libfakeuid.so" ]]
[[ "${WRIX_TERM_ROWS:-}" =~ ^[0-9]+$ ]]
[[ "${WRIX_TERM_COLS:-}" =~ ^[0-9]+$ ]]
[[ "${1:-}" == "alpha" ]]
[[ "${2:-}" == "two words" ]]
printf 'MICROVM_BOUNDARY_OK=%s|%s\n' "$1" "$2"
INNER
  chmod +x "$workspace/assert-microvm.sh"

  command=(
    "$sandbox/bin/wrix" run "$workspace"
    /workspace/assert-microvm.sh alpha "two words"
  )
  printf -v command_line '%q ' "${command[@]}"
  output=$(WRIX_MICROVM=1 wrix_run_with_pty "$command_line")

  if [[ "$output" != *"MICROVM_BOUNDARY_OK=alpha|two words"* ]]; then
    fail "live krun microVM did not reach the relay/init/libfakeuid boundary: $output"
    return 1
  fi
  printf 'PASS: live launcher reached the krun relay/init/libfakeuid boundary\n'
}

test_linux_microvm_runtime
