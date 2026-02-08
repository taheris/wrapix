#!/usr/bin/env bash
# Test: tmux_send_keys
#
# Tests:
# 1. Create pane with bash shell
# 2. Send echo command
# 3. Send Enter key to execute
# 4. Capture output and verify "hello" is present

set -euo pipefail

# Skip if prerequisites are not available
if ! command -v tmux &>/dev/null; then
  echo "SKIP: test_send_keys.sh requires tmux (not available)"
  exit 0
fi

# shellcheck source=test_lib.sh
source "$(dirname "$0")/test_lib.sh"

if ! find_mcp_binary &>/dev/null; then
  echo "SKIP: test_send_keys.sh requires tmux-debug-mcp binary (not built)"
  exit 0
fi

main() {
    log_test "Starting send_keys tests..."

    # Start MCP server
    start_mcp_server

    # Initialize session
    log_test "Initializing MCP session..."
    local response
    response=$(mcp_initialize)
    assert_success "$response" "Initialize should succeed"
    mcp_initialized

    # Test 1: Create pane with bash shell
    log_test "Test 1: Create pane with bash shell..."
    response=$(mcp_create_pane "bash" "shell-test")
    assert_success "$response" "Create pane should succeed"

    local pane_id
    pane_id=$(extract_pane_id "$response")
    assert_ne "" "$pane_id" "Pane ID should be extracted"
    log_pass "Created shell pane: $pane_id"

    # Wait for shell to start
    sleep 0.5

    # Test 2: Send echo command
    log_test "Test 2: Send 'echo hello' to pane..."
    response=$(mcp_send_keys "$pane_id" "echo hello")
    assert_success "$response" "Send keys should succeed"
    assert_contains "$(get_content_text "$response")" "Sent keys" "Response should confirm keys sent"
    log_pass "Sent echo command"

    # Test 3: Send Enter key to execute
    log_test "Test 3: Send Enter key..."
    response=$(mcp_send_keys "$pane_id" "Enter")
    assert_success "$response" "Send Enter should succeed"
    log_pass "Sent Enter key"

    # Wait for command to execute
    sleep 0.3

    # Test 4: Capture and verify output
    log_test "Test 4: Capture output and verify 'hello'..."
    response=$(mcp_capture_pane "$pane_id" 50)
    assert_success "$response" "Capture should succeed"

    local content
    content=$(get_content_text "$response")
    assert_contains "$content" "hello" "Output should contain 'hello'"
    log_pass "Output contains 'hello'"

    # Test 5: Send multiple commands
    log_test "Test 5: Send multiple commands..."
    response=$(mcp_send_keys "$pane_id" "echo world")
    assert_success "$response" "Send keys should succeed"
    response=$(mcp_send_keys "$pane_id" "Enter")
    assert_success "$response" "Send Enter should succeed"

    sleep 0.3

    response=$(mcp_capture_pane "$pane_id" 50)
    content=$(get_content_text "$response")
    assert_contains "$content" "world" "Output should contain 'world'"
    log_pass "Multiple commands work"

    # Test 6: Send special keys (Ctrl-C as ^C)
    log_test "Test 6: Send special key (Ctrl-C)..."
    # Start a long-running command
    response=$(mcp_send_keys "$pane_id" "sleep 100")
    assert_success "$response"
    response=$(mcp_send_keys "$pane_id" "Enter")
    assert_success "$response"

    sleep 0.2

    # Send Ctrl-C to interrupt
    response=$(mcp_send_keys "$pane_id" "^C")
    assert_success "$response" "Send Ctrl-C should succeed"
    log_pass "Ctrl-C sent successfully"

    # Cleanup
    log_test "Cleanup: killing pane..."
    mcp_kill_pane "$pane_id" >/dev/null

    echo ""
    log_pass "All send_keys tests passed!"
    return 0
}

main "$@"
