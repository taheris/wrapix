#!/usr/bin/env bash
# Test: Cleanup on exit
#
# Tests:
# 1. Start MCP server
# 2. Create multiple panes
# 3. Verify tmux session exists
# 4. Kill MCP server
# 5. Verify tmux session is cleaned up

set -euo pipefail

# shellcheck source=test_lib.sh
source "$(dirname "$0")/test_lib.sh"

main() {
    log_test "Starting cleanup_on_exit tests..."

    # Start MCP server
    start_mcp_server

    # Initialize session
    log_test "Initializing MCP session..."
    local response
    response=$(mcp_initialize)
    assert_success "$response" "Initialize should succeed"
    mcp_initialized

    # Create multiple panes
    log_test "Creating multiple panes..."
    response=$(mcp_create_pane "sleep 300" "cleanup-1")
    local pane_id1
    pane_id1=$(extract_pane_id "$response")
    log_pass "Created pane 1: $pane_id1"

    response=$(mcp_create_pane "sleep 300" "cleanup-2")
    local pane_id2
    pane_id2=$(extract_pane_id "$response")
    log_pass "Created pane 2: $pane_id2"

    response=$(mcp_create_pane "sleep 300" "cleanup-3")
    local pane_id3
    pane_id3=$(extract_pane_id "$response")
    log_pass "Created pane 3: $pane_id3"

    # Get session name
    local session_name
    session_name=$(get_mcp_session_name)
    log_info "MCP session name: $session_name"

    # Verify tmux session exists
    log_test "Verifying tmux session exists before cleanup..."
    assert_tmux_session_exists "$session_name" "Session should exist with running panes"

    # Count windows in session
    local window_count
    window_count=$(tmux list-windows -t "$session_name" 2>/dev/null | wc -l)
    log_info "Window count: $window_count"

    if [[ "$window_count" -lt 3 ]]; then
        log_warn "Expected at least 3 windows, got $window_count"
    fi
    log_pass "Tmux session exists with windows"

    # Kill MCP server (simulating exit)
    log_test "Killing MCP server..."
    local saved_pid="$MCP_PID"

    # Close file descriptors first
    exec 3>&- 2>/dev/null || true
    exec 4<&- 2>/dev/null || true
    MCP_FD_IN=""
    MCP_FD_OUT=""

    # Kill the server process
    kill "$saved_pid" 2>/dev/null || true

    # Wait for it to exit
    wait "$saved_pid" 2>/dev/null || true
    MCP_PID=""
    log_pass "MCP server killed"

    # Wait a moment for cleanup
    sleep 0.5

    # Verify tmux session is cleaned up
    log_test "Verifying tmux session is cleaned up..."

    # The session should no longer exist
    if tmux has-session -t "$session_name" 2>/dev/null; then
        log_fail "Tmux session should be cleaned up after server exit"
        log_error "Session $session_name still exists"
        # Clean up manually for test
        tmux kill-session -t "$session_name" 2>/dev/null || true
        exit 1
    fi
    log_pass "Tmux session cleaned up on server exit"

    # Clean up fifos
    rm -f "$MCP_FIFO_IN" "$MCP_FIFO_OUT" 2>/dev/null || true
    MCP_FIFO_IN=""
    MCP_FIFO_OUT=""

    # Test 2: Verify cleanup with SIGTERM
    log_test "Test: Verify cleanup with SIGTERM..."

    # Start a new server
    start_mcp_server
    response=$(mcp_initialize)
    assert_success "$response"
    mcp_initialized

    response=$(mcp_create_pane "sleep 300" "sigterm-test")
    local pane_id
    pane_id=$(extract_pane_id "$response")

    session_name=$(get_mcp_session_name)
    assert_tmux_session_exists "$session_name"
    log_pass "New session created"

    # Send SIGTERM
    saved_pid="$MCP_PID"
    exec 3>&- 2>/dev/null || true
    exec 4<&- 2>/dev/null || true
    MCP_FD_IN=""
    MCP_FD_OUT=""

    kill -TERM "$saved_pid" 2>/dev/null || true
    wait "$saved_pid" 2>/dev/null || true
    MCP_PID=""

    sleep 0.5

    if tmux has-session -t "$session_name" 2>/dev/null; then
        log_fail "Session should be cleaned up after SIGTERM"
        tmux kill-session -t "$session_name" 2>/dev/null || true
        exit 1
    fi
    log_pass "Session cleaned up after SIGTERM"

    # Clean up fifos
    rm -f "$MCP_FIFO_IN" "$MCP_FIFO_OUT" 2>/dev/null || true
    MCP_FIFO_IN=""
    MCP_FIFO_OUT=""

    echo ""
    log_pass "All cleanup_on_exit tests passed!"
    return 0
}

main "$@"
