#!/usr/bin/env bash
# Verifies pre-push-checks falls through when marker metadata is incomplete.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/prek/wrapper-test-lib.sh
source "$SCRIPT_DIR/wrapper-test-lib.sh"

TEST_TMP="$(mktemp -d -t wrix-prek-no-metadata.XXXXXX)"
trap 'rm -rf "$TEST_TMP"' EXIT

wrix_prek_require_tool bash
wrix_prek_require_tool git
wrix_prek_require_tool touch
BASH_BIN="$(command -v bash)"
GIT_DIR="$(dirname "$(command -v git)")"
TOUCH_BIN="$(command -v touch)"
PRE_PUSH_CHECKS_BIN="$(wrix_prek_wrapper_bin prePushChecks pre-push-checks)"
PRE_PUSH_CHECKS_DIR="$(dirname "$PRE_PUSH_CHECKS_BIN")"

LOOM_CALL_LOG="$TEST_TMP/loom-calls"
LOOM_SHIM="$TEST_TMP/loom-bin/loom"
mkdir -p "$(dirname "$LOOM_SHIM")"
cat >"$LOOM_SHIM" <<EOF
#!$BASH_BIN
set -euo pipefail
echo "loom shim invoked with: \$*" >>"$LOOM_CALL_LOG"
exit 0
EOF
chmod +x "$LOOM_SHIM"

WORK="$TEST_TMP/work"
mkdir -p "$WORK/.loom"
git -C "$WORK" init -q
echo '{}' >"$WORK/.loom/marker.json"

MISSING_ID_SENTINEL="$TEST_TMP/missing-id-sentinel"
MISSING_ENTRY_SENTINEL="$TEST_TMP/missing-entry-sentinel"

missing_id_rc=0
(
  cd "$WORK"
  PATH="$TEST_TMP/loom-bin:$PRE_PUSH_CHECKS_DIR:$GIT_DIR" \
    pre-push-checks "$TOUCH_BIN" "$MISSING_ID_SENTINEL"
) || missing_id_rc=$?

if [[ "$missing_id_rc" -ne 0 ]]; then
  echo "FAIL: wrapper without hook id exited $missing_id_rc; expected 0" >&2
  exit 1
fi

missing_entry_rc=0
(
  cd "$WORK"
  PATH="$TEST_TMP/loom-bin:$PRE_PUSH_CHECKS_DIR:$GIT_DIR" \
    pre-push-checks --hook-id missing-entry -- "$TOUCH_BIN" "$MISSING_ENTRY_SENTINEL"
) || missing_entry_rc=$?

if [[ "$missing_entry_rc" -ne 0 ]]; then
  echo "FAIL: wrapper without hook entry exited $missing_entry_rc; expected 0" >&2
  exit 1
fi

if [[ ! -e "$MISSING_ID_SENTINEL" || ! -e "$MISSING_ENTRY_SENTINEL" ]]; then
  echo "FAIL: incomplete metadata did not fall through to both wrapped commands" >&2
  exit 1
fi

if [[ -e "$LOOM_CALL_LOG" ]]; then
  echo "FAIL: loom shim was invoked despite incomplete metadata: $(<"$LOOM_CALL_LOG")" >&2
  exit 1
fi

printf 'PASS: incomplete marker metadata → wrapper execed wrapped command\n'
