#!/usr/bin/env bash
set -euo pipefail

TCP_PORT=5959
DARWIN_GATEWAY="192.168.64.1"
LINUX_SOCKET="/run/wrix/notify.sock"
CONNECT_TIMEOUT_SECONDS=3
TEST_TMP=""
BACKGROUND_PIDS=()

ensure_tmp() {
  if [[ -z "$TEST_TMP" ]]; then
    TEST_TMP=$(mktemp -d -t wrix-notify-test.XXXXXX)
    trap cleanup EXIT
  fi
}

cleanup() {
  local pid

  for pid in "${BACKGROUND_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true # best-effort: test listeners may already have exited.
    wait "$pid" 2>/dev/null || true # best-effort: reap listeners that are still tracked.
  done
  if [[ -n "$TEST_TMP" ]]; then
    rm -rf "$TEST_TMP"
  fi
}

fail() {
  local message="$1"

  echo "FAIL: $message" >&2
  exit 1
}

fail_with_output() {
  local message="$1"
  local output_file="$2"

  echo "FAIL: $message" >&2
  if [[ -s "$output_file" ]]; then
    sed 's/^/  /' "$output_file" >&2
  fi
  exit 1
}

skip() {
  local message="$1"

  echo "SKIP: $message"
  exit 77
}

pass() {
  local message="$1"

  echo "PASS: $message"
}

require_command() {
  local name="$1"

  if ! command -v "$name" >/dev/null 2>&1; then
    fail "required command not found on PATH: $name"
  fi
}

require_command_or_skip() {
  local name="$1"

  if ! command -v "$name" >/dev/null 2>&1; then
    skip "command not available on this platform: $name"
  fi
}

resolve_repo_root() {
  local git_root

  if [[ -n "${REPO_ROOT:-}" ]]; then
    printf '%s\n' "$REPO_ROOT"
    return 0
  fi

  if git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$git_root"
    return 0
  fi

  pwd
}

wait_for_unix_socket() {
  local socket="$1"
  local attempt

  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if [[ -S "$socket" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_tcp_listener() {
  local host="$1"
  local port="$2"
  local attempt

  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if nc -z -w "$CONNECT_TIMEOUT_SECONDS" "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_capture() {
  local capture="$1"
  local attempt

  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if [[ -s "$capture" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_text() {
  local file="$1"
  local expected="$2"
  local attempt

  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if [[ -f "$file" && "$(<"$file")" == *"$expected"* ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

start_tcp_capture() {
  local host="$1"
  local port="$2"
  local capture="$3"
  local log_file="$4"
  local pid

  : >"$capture"
  socat -u TCP-LISTEN:"$port",bind="$host",fork,reuseaddr OPEN:"$capture",creat,append >"$log_file" 2>&1 &
  pid="$!"
  BACKGROUND_PIDS+=("$pid")
  wait_for_tcp_listener "$host" "$port"
}

start_notify_daemon() {
  local runtime_dir="$1"
  local capture="$2"
  local log_file="$3"
  local always="$4"
  local verbose="$5"
  local dispatch_time_capture="$6"
  local pid

  mkdir -p "$runtime_dir/wrix" "$runtime_dir/data"
  : >"$capture"
  XDG_DATA_HOME="$runtime_dir/data" \
    XDG_RUNTIME_DIR="$runtime_dir" \
    WRIX_NOTIFY_ALWAYS="$always" \
    WRIX_NOTIFY_VERBOSE="$verbose" \
    WRIX_NOTIFY_TEST_DISPATCH_CAPTURE="$capture" \
    WRIX_NOTIFY_TEST_DISPATCH_TIME_CAPTURE="$dispatch_time_capture" \
    wrix-notifyd >"$log_file" 2>&1 &
  pid="$!"
  BACKGROUND_PIDS+=("$pid")

  case "$(uname -s)" in
    Linux) wait_for_unix_socket "$runtime_dir/wrix/notify.sock" ;;
    Darwin) wait_for_tcp_listener "$DARWIN_GATEWAY" "$TCP_PORT" ;;
    *) return 1 ;;
  esac
}

stop_background_process() {
  local pid="$1"

  kill "$pid"
  wait "$pid" 2>/dev/null || true # best-effort: a terminated daemon exits non-zero when reaped.
}

send_daemon_envelope() {
  local runtime_dir="$1"
  local payload="$2"

  case "$(uname -s)" in
    Linux) printf '%s\n' "$payload" | socat -u - "UNIX-CONNECT:$runtime_dir/wrix/notify.sock" ;;
    Darwin) printf '%s\n' "$payload" | socat -u - "TCP:$DARWIN_GATEWAY:$TCP_PORT" ;;
    *) fail "unsupported platform: $(uname -s)" ;;
  esac
}

assert_single_json_envelope() {
  local capture="$1"
  local count

  if ! count=$(jq -s 'length' "$capture"); then
    fail "captured payload was not valid JSONL"
  fi
  if [[ "$count" != "1" ]]; then
    fail "captured $count JSON envelopes, expected 1"
  fi
}

assert_json_field() {
  local capture="$1"
  local field="$2"
  local expected="$3"
  local actual

  actual=$(jq -sr --arg field "$field" '.[0][$field]' "$capture")
  if [[ "$actual" != "$expected" ]]; then
    fail "captured .$field was '$actual', expected '$expected'"
  fi
}

assert_native_dispatch() {
  local capture="$1"
  local title="$2"
  local message="$3"
  local sound="$4"

  case "$(uname -s)" in
    Linux)
      if ! jq -se --arg title "$title" --arg message "$message" \
        'length == 1 and .[0] == [$title, $message]' "$capture" >/dev/null; then
        fail_with_output "wrix-notifyd did not dispatch the Linux notification payload" "$capture"
      fi
      ;;
    Darwin)
      if ! jq -se --arg title "$title" --arg message "$message" --arg sound "$sound" \
        'length == 1 and .[0] == ["-title", $title, "-message", $message, "-sound", $sound]' \
        "$capture" >/dev/null; then
        fail_with_output "wrix-notifyd did not dispatch the Darwin notification payload" "$capture"
      fi
      ;;
    *) fail "unsupported platform: $(uname -s)" ;;
  esac
}

assert_dispatch_latency() {
  local start_time_file="$1"
  local dispatch_time_file="$2"
  local start_time
  local dispatch_time
  local elapsed

  if [[ ! -s "$start_time_file" || ! -s "$dispatch_time_file" ]]; then
    fail "notification latency timestamps were not recorded"
  fi
  start_time=$(<"$start_time_file")
  dispatch_time=$(<"$dispatch_time_file")
  if [[ ! "$start_time" =~ ^[0-9]+$ || ! "$dispatch_time" =~ ^[0-9]+$ ]]; then
    fail "notification latency timestamps were not numeric"
  fi
  elapsed="$((dispatch_time - start_time))"
  if [[ "$elapsed" -lt 0 || "$elapsed" -ge 1000000000 ]]; then
    fail "native bridge dispatch took $elapsed nanoseconds, expected less than one second"
  fi
}

run_notify_with_timeout() {
  local output_file="$1"
  local title="$2"
  local message="$3"
  local sound="$4"
  local rc=0

  timeout 1s wrix-notify "$title" "$message" "$sound" >"$output_file" 2>&1 || rc="$?"
  if [[ "$rc" -eq 124 ]]; then
    fail_with_output "wrix-notify waited for an acknowledgement" "$output_file"
  fi
  if [[ "$rc" -ne 0 ]]; then
    fail_with_output "wrix-notify exited non-zero" "$output_file"
  fi
}

test_client_tcp_endpoint_override() {
  ensure_tmp
  require_command nc
  require_command socat
  require_command wrix-notify

  local capture="$TEST_TMP/tcp-endpoint-capture.jsonl"
  local listener_log="$TEST_TMP/tcp-endpoint-listener.log"
  local port="$((42000 + (BASHPID % 20000)))"

  if ! start_tcp_capture "127.0.0.1" "$port" "$capture" "$listener_log"; then
    fail_with_output "could not start TCP capture listener" "$listener_log"
  fi

  WRIX_NOTIFY_TCP="127.0.0.1:$port" wrix-notify "endpoint override" "selected listener"
  if ! wait_for_capture "$capture"; then
    fail_with_output "WRIX_NOTIFY_TCP payload did not reach the selected endpoint" "$listener_log"
  fi
  pass "WRIX_NOTIFY_TCP selects the client TCP endpoint"
}

test_client_envelope() {
  ensure_tmp
  require_command jq
  require_command nc
  require_command socat
  require_command wrix-notify

  local capture="$TEST_TMP/client-envelope.jsonl"
  local listener_log="$TEST_TMP/client-envelope-listener.log"
  local port="$((42000 + (BASHPID % 20000)))"
  local title="notify envelope $BASHPID"
  local message="client payload fields"
  local sound="Ping"
  local session_id="notify-test:0.1"

  if ! start_tcp_capture "127.0.0.1" "$port" "$capture" "$listener_log"; then
    fail_with_output "could not start TCP capture listener" "$listener_log"
  fi

  WRIX_NOTIFY_TCP="127.0.0.1:$port" \
    WRIX_SESSION_ID="$session_id" \
    wrix-notify "$title" "$message" "$sound"
  if ! wait_for_capture "$capture"; then
    fail_with_output "wrix-notify envelope was not captured" "$listener_log"
  fi

  assert_single_json_envelope "$capture"
  assert_json_field "$capture" title "$title"
  assert_json_field "$capture" message "$message"
  assert_json_field "$capture" sound "$sound"
  assert_json_field "$capture" session_id "$session_id"
  pass "wrix-notify sends exactly one complete JSON envelope"
}

test_client_non_blocking() {
  ensure_tmp
  require_command nc
  require_command socat
  require_command timeout
  require_command wrix-notify

  local capture="$TEST_TMP/non-blocking-capture.jsonl"
  local listener_log="$TEST_TMP/non-blocking-listener.log"
  local output_file="$TEST_TMP/non-blocking-client.log"
  local port="$((42000 + (BASHPID % 20000)))"

  if ! start_tcp_capture "127.0.0.1" "$port" "$capture" "$listener_log"; then
    fail_with_output "could not start TCP capture listener" "$listener_log"
  fi

  WRIX_NOTIFY_TCP="127.0.0.1:$port" \
    run_notify_with_timeout "$output_file" "non-blocking client" "no acknowledgement" "Ping"
  pass "wrix-notify exits without waiting for an acknowledgement"
}

write_spawn_config() {
  local output_file="$1"
  local workspace="$2"
  local title="$3"
  local message="$4"
  local sound="$5"
  local session_id="$6"

  jq -n \
    --arg workspace "$workspace" \
    --arg title "$title" \
    --arg message "$message" \
    --arg sound "$sound" \
    --arg session_id "$session_id" \
    '{
      workspace: $workspace,
      env: [
        ["WRIX_NOTIFY_TEST_IN_CONTAINER", "1"],
        ["WRIX_NOTIFY_TEST_TITLE", $title],
        ["WRIX_NOTIFY_TEST_MESSAGE", $message],
        ["WRIX_NOTIFY_TEST_SOUND", $sound],
        ["WRIX_NOTIFY_TEST_START_TIME_FILE", "/workspace/notify-started-ns"],
        ["WRIX_SESSION_ID", $session_id]
      ],
      agent_args: ["bash", "/workspace/notify-test.sh", "--inside-container"]
    }' >"$output_file"
}

run_spawned_container_check() {
  local spawn_config="$1"
  local output_file="$2"
  local repo_root="$3"
  local runtime_dir="$4"
  local deploy_key="$5"
  local rc=0

  (
    cd "$repo_root"
    XDG_RUNTIME_DIR="$runtime_dir" \
      WRIX_DEPLOY_KEY="$deploy_key" \
      WRIX_GIT_SIGN=0 \
      nix run --no-warn-dirty .#sandbox -- spawn --spawn-config "$spawn_config"
  ) >"$output_file" 2>&1 || rc="$?"

  if [[ "$rc" -ne 0 ]]; then
    fail_with_output "wrix spawn notification check failed" "$output_file"
  fi
}

test_container_payload_inside() {
  require_command timeout
  require_command wrix-notify

  local title="${WRIX_NOTIFY_TEST_TITLE:?}"
  local message="${WRIX_NOTIFY_TEST_MESSAGE:?}"
  local sound="${WRIX_NOTIFY_TEST_SOUND:?}"
  local output_file="/tmp/wrix-notify-inside.log"
  local start_time_file="${WRIX_NOTIFY_TEST_START_TIME_FILE:-}"

  if [[ -n "${WRIX_NOTIFY_TCP:-}" ]]; then
    if [[ "$WRIX_NOTIFY_TCP" != *:* ]]; then
      fail "WRIX_NOTIFY_TCP inside the container is not host:port: $WRIX_NOTIFY_TCP"
    fi
  elif [[ ! -S "$LINUX_SOCKET" ]]; then
    fail "notification socket was not mounted at $LINUX_SOCKET"
  fi

  if [[ -n "$start_time_file" ]]; then
    date +%s%N >"$start_time_file"
  fi
  run_notify_with_timeout "$output_file" "$title" "$message" "$sound"
}

run_container_check_linux() {
  local assertion="$1"

  ensure_tmp
  require_command jq
  require_command nc
  require_command nix
  require_command wrix-notifyd
  require_command_or_skip podman

  if [[ "$(uname -s)" != "Linux" ]]; then
    skip "Linux notification transport is not available on this platform"
  fi
  if ! podman info >/dev/null 2>&1; then
    skip "podman runtime is not available"
  fi
  if [[ ! -c /dev/net/tun ]]; then
    skip "podman runtime cannot launch wrix networking without /dev/net/tun"
  fi

  local runtime_dir="$TEST_TMP/runtime"
  local capture="$TEST_TMP/linux-dispatch.jsonl"
  local dispatch_time="$TEST_TMP/linux-dispatch-ns"
  local daemon_log="$TEST_TMP/wrix-notifyd.log"
  local output_file="$TEST_TMP/wrix-spawn.log"
  local workspace="$TEST_TMP/workspace"
  local start_time="$workspace/notify-started-ns"
  local spawn_config="$TEST_TMP/spawn.json"
  local deploy_key="$TEST_TMP/deploy_key"
  local title="notify container linux $BASHPID"
  local message="container payload reached unix daemon"
  local sound="Ping"
  local session_id="notify-test:0.1"
  local repo_root

  repo_root=$(resolve_repo_root)
  mkdir -p "$runtime_dir/libpod/tmp" "$workspace"
  cp "$repo_root/tests/standalone/notify-test.sh" "$workspace/notify-test.sh"
  printf 'not-a-real-key\n' >"$deploy_key"
  chmod 600 "$deploy_key"

  if ! start_notify_daemon "$runtime_dir" "$capture" "$daemon_log" "1" "0" "$dispatch_time"; then
    fail_with_output "could not start wrix-notifyd Unix socket listener" "$daemon_log"
  fi

  write_spawn_config "$spawn_config" "$workspace" "$title" "$message" "$sound" "$session_id"
  run_spawned_container_check "$spawn_config" "$output_file" "$repo_root" "$runtime_dir" "$deploy_key"

  if ! wait_for_capture "$capture"; then
    fail_with_output "wrix-notifyd did not dispatch the container payload" "$daemon_log"
  fi

  case "$assertion" in
    latency)
      assert_dispatch_latency "$start_time" "$dispatch_time"
      pass "container notification reaches the Linux native bridge within one second"
      ;;
    transport)
      assert_native_dispatch "$capture" "$title" "$message" "$sound"
      pass "container wrix-notify reaches the host Unix socket daemon and native bridge"
      ;;
    *) fail "unknown Linux container assertion: $assertion" ;;
  esac
}

run_container_check_darwin() {
  local assertion="$1"

  ensure_tmp
  require_command jq
  require_command nc
  require_command nix
  require_command wrix-notifyd
  require_command_or_skip container

  if [[ "$(uname -s)" != "Darwin" ]]; then
    skip "Darwin notification transport is not available on this platform"
  fi

  local runtime_dir="$TEST_TMP/runtime"
  local capture="$TEST_TMP/darwin-dispatch.jsonl"
  local dispatch_time="$TEST_TMP/darwin-dispatch-ns"
  local daemon_log="$TEST_TMP/wrix-notifyd.log"
  local output_file="$TEST_TMP/wrix-spawn.log"
  local workspace="$TEST_TMP/workspace"
  local start_time="$workspace/notify-started-ns"
  local spawn_config="$TEST_TMP/spawn.json"
  local deploy_key="$TEST_TMP/deploy_key"
  local title="notify container darwin $BASHPID"
  local message="container payload reached tcp daemon"
  local sound="Ping"
  local session_id="notify-test:0.1"
  local repo_root

  repo_root=$(resolve_repo_root)
  mkdir -p "$workspace"
  cp "$repo_root/tests/standalone/notify-test.sh" "$workspace/notify-test.sh"
  printf 'not-a-real-key\n' >"$deploy_key"
  chmod 600 "$deploy_key"

  if ! start_notify_daemon "$runtime_dir" "$capture" "$daemon_log" "1" "0" "$dispatch_time"; then
    fail_with_output "could not start wrix-notifyd TCP listener" "$daemon_log"
  fi

  write_spawn_config "$spawn_config" "$workspace" "$title" "$message" "$sound" "$session_id"
  run_spawned_container_check "$spawn_config" "$output_file" "$repo_root" "$runtime_dir" "$deploy_key"

  if ! wait_for_capture "$capture"; then
    fail_with_output "wrix-notifyd did not dispatch the container payload" "$daemon_log"
  fi

  case "$assertion" in
    latency)
      assert_dispatch_latency "$start_time" "$dispatch_time"
      pass "container notification reaches the Darwin native bridge within one second"
      ;;
    transport)
      assert_native_dispatch "$capture" "$title" "$message" "$sound"
      pass "container wrix-notify reaches the host TCP daemon and native bridge"
      ;;
    *) fail "unknown Darwin container assertion: $assertion" ;;
  esac
}

test_container_transport_linux() {
  run_container_check_linux transport
}

test_container_transport_darwin() {
  run_container_check_darwin transport
}

test_daemon_dispatch_latency() {
  case "$(uname -s)" in
    Linux) run_container_check_linux latency ;;
    Darwin) run_container_check_darwin latency ;;
    *) skip "unsupported platform: $(uname -s)" ;;
  esac
}

write_focus_fixture() {
  local runtime_dir="$1"
  local bin_dir="$2"
  local session_id="$3"
  local safe_id
  local session_dir

  safe_id=$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9_-' '-')
  case "$(uname -s)" in
    Linux)
      session_dir="$runtime_dir/wrix/sessions"
      mkdir -p "$session_dir"
      jq -n --arg session_id "$session_id" --arg window_id "focused-window" \
        '{session_id: $session_id, window_id: $window_id}' >"$session_dir/$safe_id.json"
      cat >"$bin_dir/niri" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"id":"focused-window"}'
EOF
      chmod +x "$bin_dir/niri"
      ;;
    Darwin)
      session_dir="$runtime_dir/data/wrix/sessions"
      mkdir -p "$session_dir"
      jq -n --arg session_id "$session_id" --arg terminal_app "FocusedTerminal" \
        '{session_id: $session_id, terminal_app: $terminal_app}' >"$session_dir/$safe_id.json"
      cat >"$bin_dir/osascript" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'FocusedTerminal'
EOF
      chmod +x "$bin_dir/osascript"
      ;;
    *) skip "unsupported platform: $(uname -s)" ;;
  esac

  cat >"$bin_dir/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
  chmod +x "$bin_dir/tmux"
}

test_focus_override() {
  ensure_tmp
  require_command jq
  require_command nc
  require_command socat
  require_command wrix-notifyd

  local baseline_runtime="$TEST_TMP/focus-baseline"
  local baseline_capture="$TEST_TMP/focus-baseline.jsonl"
  local baseline_log="$TEST_TMP/focus-baseline.log"
  local override_runtime="$TEST_TMP/focus-override"
  local override_capture="$TEST_TMP/focus-override.jsonl"
  local override_log="$TEST_TMP/focus-override.log"
  local bin_dir="$TEST_TMP/focus-bin"
  local session_id="focus-test:0.1"
  local payload
  local daemon_pid

  mkdir -p "$bin_dir"
  write_focus_fixture "$baseline_runtime" "$bin_dir" "$session_id"
  payload=$(jq -cn --arg session_id "$session_id" \
    '{title: "focus override", message: "dispatch", sound: "Ping", session_id: $session_id}')

  if ! PATH="$bin_dir:$PATH" start_notify_daemon \
    "$baseline_runtime" "$baseline_capture" "$baseline_log" "0" "1" ""; then
    fail_with_output "could not start baseline focus daemon" "$baseline_log"
  fi
  daemon_pid="${BACKGROUND_PIDS[-1]}"
  send_daemon_envelope "$baseline_runtime" "$payload"
  if ! wait_for_text "$baseline_log" "notifyd: suppressed (terminal focused)"; then
    fail_with_output "baseline daemon did not positively identify the focused target" "$baseline_log"
  fi
  if [[ -s "$baseline_capture" ]]; then
    fail_with_output "baseline focused notification was not suppressed" "$baseline_capture"
  fi
  stop_background_process "$daemon_pid"

  write_focus_fixture "$override_runtime" "$bin_dir" "$session_id"
  if ! PATH="$bin_dir:$PATH" start_notify_daemon \
    "$override_runtime" "$override_capture" "$override_log" "1" "0" ""; then
    fail_with_output "could not start focus-override daemon" "$override_log"
  fi
  send_daemon_envelope "$override_runtime" "$payload"
  if ! wait_for_capture "$override_capture"; then
    fail_with_output "WRIX_NOTIFY_ALWAYS did not bypass focus checking" "$override_log"
  fi
  pass "WRIX_NOTIFY_ALWAYS=1 disables focus checking"
}

test_verbose_logging() {
  ensure_tmp
  require_command jq
  require_command nc
  require_command socat
  require_command wrix-notify
  require_command wrix-notifyd

  local client_log="$TEST_TMP/verbose-client.log"
  local runtime_dir="$TEST_TMP/verbose-runtime"
  local capture="$TEST_TMP/verbose-dispatch.jsonl"
  local daemon_log="$TEST_TMP/verbose-daemon.log"
  local payload

  WRIX_NOTIFY_TCP="invalid-endpoint" WRIX_NOTIFY_VERBOSE=1 \
    wrix-notify "verbose client" "invalid endpoint" >"$client_log" 2>&1
  if [[ "$(<"$client_log")" != *"wrix-notify: invalid TCP endpoint: invalid-endpoint"* ]]; then
    fail_with_output "WRIX_NOTIFY_VERBOSE did not enable client diagnostics" "$client_log"
  fi

  if ! start_notify_daemon "$runtime_dir" "$capture" "$daemon_log" "0" "1" ""; then
    fail_with_output "could not start verbose notification daemon" "$daemon_log"
  fi
  payload=$(jq -cn \
    '{title: "verbose daemon", message: "missing session", sound: "Ping", session_id: "missing:0.1"}')
  send_daemon_envelope "$runtime_dir" "$payload"
  if ! wait_for_capture "$capture"; then
    fail_with_output "verbose daemon did not dispatch the test payload" "$daemon_log"
  fi
  if [[ "$(<"$daemon_log")" != *"notifyd: session file not found:"* ]]; then
    fail_with_output "WRIX_NOTIFY_VERBOSE did not enable daemon diagnostics" "$daemon_log"
  fi
  pass "WRIX_NOTIFY_VERBOSE=1 enables notification diagnostics"
}

main() {
  local test_name="${1:-}"

  if [[ -z "$test_name" ]]; then
    case "$(uname -s)" in
      Linux) test_name="test_container_transport_linux" ;;
      Darwin) test_name="test_container_transport_darwin" ;;
      *) skip "unsupported platform: $(uname -s)" ;;
    esac
  fi

  case "$test_name" in
    --inside-container) test_container_payload_inside ;;
    test_client_envelope) test_client_envelope ;;
    test_client_non_blocking) test_client_non_blocking ;;
    test_client_tcp_endpoint_override) test_client_tcp_endpoint_override ;;
    test_container_transport_darwin) test_container_transport_darwin ;;
    test_container_transport_linux) test_container_transport_linux ;;
    test_daemon_dispatch_latency) test_daemon_dispatch_latency ;;
    test_focus_override) test_focus_override ;;
    test_verbose_logging) test_verbose_logging ;;
    *) fail "unknown notify test: $test_name" ;;
  esac
}

main "$@"
