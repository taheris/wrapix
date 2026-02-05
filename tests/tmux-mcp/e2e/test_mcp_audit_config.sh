#!/usr/bin/env bash
# Test: Verify MCP audit configuration is properly passed to the container
#
# This test verifies that the audit configuration option in MCP opt-in
# is properly handled:
#
# 1. Build sandbox with audit configuration:
#    mkSandbox { profile = base; mcp = { tmux-debug = { audit = "/path"; }; }; }
# 2. Verify TMUX_DEBUG_AUDIT environment variable is set in container
# 3. Verify the MCP server configuration includes the audit path
#
# Prerequisites:
# - nix (with flakes enabled)
# - podman
#
# Usage: ./test_mcp_audit_config.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../../.."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# shellcheck disable=SC2317,SC2329  # cleanup is used by trap
cleanup() {
    local exit_code=$?
    if [[ -n "${WORKSPACE:-}" ]] && [[ -d "${WORKSPACE}" ]]; then
        rm -rf "${WORKSPACE}"
    fi
    exit "$exit_code"
}
trap cleanup EXIT

# Check prerequisites
if ! command -v nix &>/dev/null; then
    log_error "nix is required but not installed"
    exit 1
fi

if ! command -v podman &>/dev/null; then
    log_error "podman is required but not installed"
    exit 1
fi

log_info "Building wrapix image with MCP opt-in including audit configuration..."

# Build the debug-audit profile image using MCP opt-in
# The flake defines: mkSandbox { profile = base; mcp = { tmux-debug = { audit = "/workspace/.debug-audit.log"; }; }; }
IMAGE_PATH=$(nix build "${REPO_ROOT}#wrapix-debug-audit" --print-out-paths 2>/dev/null) || {
    log_error "Failed to build wrapix-debug-audit image"
    log_warn "Check that the mcp parameter with audit option is properly configured"
    exit 1
}

if [[ ! -f "${IMAGE_PATH}" ]]; then
    log_error "Built image not found at ${IMAGE_PATH}"
    exit 1
fi

log_info "Image built: ${IMAGE_PATH}"

# Create a temporary workspace
WORKSPACE=$(mktemp -d)
log_info "Using workspace: ${WORKSPACE}"

FAILED=0

log_info "=== Checking audit configuration ==="

# Check that the Claude settings contain the MCP server configuration with audit
log_info "Verifying Claude settings contain MCP server configuration..."

CLAUDE_SETTINGS=$(podman run --rm \
    --network=pasta \
    --userns=keep-id \
    --entrypoint /bin/bash \
    -v "${WORKSPACE}:/workspace:rw" \
    -w /workspace \
    "docker-archive:${IMAGE_PATH}" \
    -c "cat ~/.claude/settings.json 2>/dev/null || echo 'not-found'" 2>&1)

if [[ "${CLAUDE_SETTINGS}" == "not-found" ]]; then
    log_error "FAIL: Claude settings file not found in container"
    FAILED=1
else
    log_info "Claude settings found"

    # Check if mcpServers contains tmux-debug with audit env
    if echo "${CLAUDE_SETTINGS}" | grep -q '"tmux-debug"'; then
        log_info "PASS: tmux-debug MCP server found in settings"
    else
        log_error "FAIL: tmux-debug MCP server not found in settings"
        echo "Settings: ${CLAUDE_SETTINGS}"
        FAILED=1
    fi

    # Check for TMUX_DEBUG_AUDIT environment variable in the config
    if echo "${CLAUDE_SETTINGS}" | grep -q 'TMUX_DEBUG_AUDIT'; then
        log_info "PASS: TMUX_DEBUG_AUDIT env var found in MCP configuration"
    else
        log_error "FAIL: TMUX_DEBUG_AUDIT env var not found in MCP configuration"
        echo "Settings: ${CLAUDE_SETTINGS}"
        FAILED=1
    fi

    # Check for the audit path value
    if echo "${CLAUDE_SETTINGS}" | grep -q '/workspace/.debug-audit.log'; then
        log_info "PASS: Audit path correctly set to /workspace/.debug-audit.log"
    else
        log_error "FAIL: Audit path not correctly set"
        echo "Settings: ${CLAUDE_SETTINGS}"
        FAILED=1
    fi
fi

echo ""
log_info "=== Checking tmux-debug-mcp is present ==="

# Verify tmux-debug-mcp is in PATH
MCP_PATH=$(podman run --rm \
    --network=pasta \
    --userns=keep-id \
    --entrypoint /bin/bash \
    -v "${WORKSPACE}:/workspace:rw" \
    -w /workspace \
    "docker-archive:${IMAGE_PATH}" \
    -c "which tmux-debug-mcp 2>/dev/null || echo 'not-found'" 2>&1)

if [[ "${MCP_PATH}" == "not-found" ]]; then
    log_error "FAIL: tmux-debug-mcp not found in PATH"
    FAILED=1
else
    log_info "PASS: tmux-debug-mcp found at ${MCP_PATH}"
fi

# Verify tmux is also present
TMUX_PATH=$(podman run --rm \
    --network=pasta \
    --userns=keep-id \
    --entrypoint /bin/bash \
    -v "${WORKSPACE}:/workspace:rw" \
    -w /workspace \
    "docker-archive:${IMAGE_PATH}" \
    -c "which tmux 2>/dev/null || echo 'not-found'" 2>&1)

if [[ "${TMUX_PATH}" == "not-found" ]]; then
    log_error "FAIL: tmux not found in PATH"
    FAILED=1
else
    log_info "PASS: tmux found at ${TMUX_PATH}"
fi

echo ""
echo "========================================="
if [[ $FAILED -eq 0 ]]; then
    log_info "SUCCESS: All MCP audit configuration checks passed!"
    echo ""
    echo "Summary:"
    echo "  - Audited MCP opt-in builds successfully"
    echo "  - tmux-debug MCP server configured in Claude settings"
    echo "  - TMUX_DEBUG_AUDIT environment variable set"
    echo "  - Audit path correctly configured"
    echo "  - MCP server binary present in container"
    exit 0
else
    log_error "FAILED: Some MCP audit configuration checks failed"
    exit 1
fi
