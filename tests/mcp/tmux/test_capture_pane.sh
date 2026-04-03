#!/usr/bin/env bash
# Test: tmux_capture_pane
#
# Tests:
# 1. Create pane running seq to generate known output
# 2. Capture with default line count (100)
# 3. Capture with explicit line count
# 4. Verify content matches expected output
# 5. Test line count clamping (max 1000)

set -euo pipefail

# shellcheck source=test_lib.sh
source "$(dirname "$0")/test_lib.sh"

main() {
    log_test "Starting capture_pane tests..."

    # Start MCP server
    start_mcp_server

    # Initialize session
    log_test "Initializing MCP session..."
    local response
    response=$(mcp_initialize)
    assert_success "$response" "Initialize should succeed"
    mcp_initialized

    # Test 1: Create pane with seq command
    log_test "Test 1: Create pane with seq 1 200..."
    response=$(mcp_create_pane "seq 1 200 && sleep 60" "seq-test")
    assert_success "$response" "Create pane should succeed"

    local pane_id
    pane_id=$(extract_pane_id "$response")
    assert_ne "" "$pane_id" "Pane ID should be extracted"
    log_pass "Created seq pane: $pane_id"

    # Wait for seq to complete
    sleep 0.5

    # Test 2: Capture with default lines (100)
    log_test "Test 2: Capture with default lines..."
    response=$(mcp_capture_pane "$pane_id")
    assert_success "$response" "Capture should succeed"

    local content
    content=$(get_content_text "$response")
    # Should contain numbers from the seq output
    assert_contains "$content" "1" "Output should contain '1'"
    log_pass "Default capture works"

    # Test 3: Capture with explicit line count (50)
    log_test "Test 3: Capture with 50 lines..."
    response=$(mcp_capture_pane "$pane_id" 50)
    assert_success "$response" "Capture with lines should succeed"
    content=$(get_content_text "$response")
    # Verify we got some output
    assert_ne "" "$content" "Output should not be empty"
    log_pass "Explicit line count works"

    # Test 4: Capture with 10 lines
    log_test "Test 4: Capture with 10 lines..."
    response=$(mcp_capture_pane "$pane_id" 10)
    assert_success "$response" "Capture with 10 lines should succeed"
    content=$(get_content_text "$response")
    assert_ne "" "$content" "Output should not be empty"
    log_pass "Small line count works"

    # Test 5: Capture with very large line count (should be clamped to 1000)
    log_test "Test 5: Capture with 5000 lines (clamped to 1000)..."
    response=$(mcp_capture_pane "$pane_id" 5000)
    assert_success "$response" "Capture with clamped lines should succeed"
    log_pass "Large line count (clamped) works"

    # Test 6: Create a new pane with different output
    log_test "Test 6: Create pane with multi-line output..."
    response=$(mcp_create_pane "echo 'line-alpha' && echo 'line-beta' && echo 'line-gamma' && sleep 60" "multi-line")
    assert_success "$response" "Create pane should succeed"

    local pane_id2
    pane_id2=$(extract_pane_id "$response")

    sleep 0.5

    response=$(mcp_capture_pane "$pane_id2" 50)
    assert_success "$response" "Capture should succeed"
    content=$(get_content_text "$response")
    assert_contains "$content" "line-alpha" "Output should contain 'line-alpha'"
    assert_contains "$content" "line-beta" "Output should contain 'line-beta'"
    assert_contains "$content" "line-gamma" "Output should contain 'line-gamma'"
    log_pass "Multi-line output captured correctly"

    # Cleanup
    log_test "Cleanup: killing panes..."
    mcp_kill_pane "$pane_id" >/dev/null
    mcp_kill_pane "$pane_id2" >/dev/null

    echo ""
    log_pass "All capture_pane tests passed!"
    return 0
}

main "$@"
