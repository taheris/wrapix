#!/usr/bin/env bash
# Test: tmux_kill_pane
#
# Tests:
# 1. Create pane
# 2. Verify pane exists in list
# 3. Kill pane
# 4. Verify pane is removed from list
# 5. Verify tmux window is gone

set -euo pipefail

# shellcheck source=test_lib.sh
source "$(dirname "$0")/test_lib.sh"

main() {
    log_test "Starting kill_pane tests..."

    # Start MCP server
    start_mcp_server

    # Initialize session
    log_test "Initializing MCP session..."
    local response
    response=$(mcp_initialize)
    assert_success "$response" "Initialize should succeed"
    mcp_initialized

    # Test 1: Create pane
    log_test "Test 1: Create pane..."
    response=$(mcp_create_pane "sleep 300" "kill-test")
    assert_success "$response" "Create pane should succeed"

    local pane_id
    pane_id=$(extract_pane_id "$response")
    assert_ne "" "$pane_id" "Pane ID should be extracted"
    log_pass "Created pane: $pane_id"

    # Test 2: Verify pane exists in list
    log_test "Test 2: Verify pane exists in list..."
    response=$(mcp_list_panes)
    assert_success "$response" "List panes should succeed"

    local content
    content=$(get_content_text "$response")
    assert_contains "$content" "$pane_id" "Pane should be in list"
    log_pass "Pane exists in list"

    # Test 3: Verify tmux session/window exists
    log_test "Test 3: Verify tmux session exists..."
    local session_name
    session_name=$(get_mcp_session_name)
    assert_tmux_session_exists "$session_name" "Session should exist before kill"
    log_pass "Tmux session exists"

    # Test 4: Kill pane
    log_test "Test 4: Kill pane..."
    response=$(mcp_kill_pane "$pane_id")
    assert_success "$response" "Kill pane should succeed"

    local kill_text
    kill_text=$(get_content_text "$response")
    assert_contains "$kill_text" "Killed" "Response should confirm kill"
    log_pass "Pane killed"

    # Test 5: Verify pane is removed from list
    log_test "Test 5: Verify pane is removed from list..."
    response=$(mcp_list_panes)
    assert_success "$response" "List panes should succeed"

    content=$(get_content_text "$response")
    assert_not_contains "$content" "$pane_id" "Pane should not be in list after kill"
    log_pass "Pane removed from list"

    # Test 6: Create multiple panes and kill them all
    log_test "Test 6: Create and kill multiple panes..."

    # Create 3 panes
    response=$(mcp_create_pane "sleep 300" "multi-1")
    local id1
    id1=$(extract_pane_id "$response")

    response=$(mcp_create_pane "sleep 300" "multi-2")
    local id2
    id2=$(extract_pane_id "$response")

    response=$(mcp_create_pane "sleep 300" "multi-3")
    local id3
    id3=$(extract_pane_id "$response")

    # Verify all exist
    response=$(mcp_list_panes)
    content=$(get_content_text "$response")
    assert_contains "$content" "$id1" "Pane 1 should exist"
    assert_contains "$content" "$id2" "Pane 2 should exist"
    assert_contains "$content" "$id3" "Pane 3 should exist"

    # Kill middle pane
    response=$(mcp_kill_pane "$id2")
    assert_success "$response" "Kill pane 2 should succeed"

    # Verify only middle is gone
    response=$(mcp_list_panes)
    content=$(get_content_text "$response")
    assert_contains "$content" "$id1" "Pane 1 should still exist"
    assert_not_contains "$content" "$id2" "Pane 2 should be gone"
    assert_contains "$content" "$id3" "Pane 3 should still exist"
    log_pass "Selective kill works"

    # Kill remaining panes
    mcp_kill_pane "$id1" >/dev/null
    mcp_kill_pane "$id3" >/dev/null

    # Verify empty list
    response=$(mcp_list_panes)
    content=$(get_content_text "$response")
    assert_contains "$content" "No active panes" "List should be empty"
    log_pass "All panes killed"

    echo ""
    log_pass "All kill_pane tests passed!"
    return 0
}

main "$@"
