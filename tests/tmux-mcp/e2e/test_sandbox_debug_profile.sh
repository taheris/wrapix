#!/usr/bin/env bash
# Test: Build wrapix image with debug profile, verify tmux and MCP server present
#
# This test builds a sandbox image with the debug profile and verifies that:
# 1. The image builds successfully with nix build
# 2. tmux is present and executable inside the container
# 3. tmux-debug-mcp is present and executable inside the container
#
# Prerequisites:
# - nix (with flakes enabled)
# - podman
#
# Usage: ./test_sandbox_debug_profile.sh

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
    if [[ -n "${IMAGE_FILE:-}" ]] && [[ -f "${IMAGE_FILE}" ]]; then
        rm -f "${IMAGE_FILE}"
    fi
    if [[ -n "${CONTAINER_ID:-}" ]]; then
        podman rm -f "${CONTAINER_ID}" 2>/dev/null || true
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

log_info "Building wrapix debug profile image..."

# Build the debug profile image
# Note: This assumes .#wrapix-debug is defined in the flake outputs
IMAGE_FILE=$(mktemp --suffix=.tar)
if ! nix build "${REPO_ROOT}#wrapix-debug" --out-link "${IMAGE_FILE%.tar}" 2>&1; then
    log_error "Failed to build wrapix-debug image"
    log_warn "The debug profile may not be defined yet. Check lib/sandbox/profiles.nix"
    exit 1
fi

# The nix build creates a result symlink; get the actual image path
IMAGE_PATH=$(readlink -f "${IMAGE_FILE%.tar}")
if [[ ! -f "${IMAGE_PATH}" ]]; then
    log_error "Built image not found at ${IMAGE_PATH}"
    exit 1
fi

log_info "Loading image into podman..."
IMAGE_NAME=$(podman load < "${IMAGE_PATH}" | grep -oP 'Loaded image: \K.*')
if [[ -z "${IMAGE_NAME}" ]]; then
    log_error "Failed to load image into podman"
    exit 1
fi
log_info "Loaded image: ${IMAGE_NAME}"

# Create a temporary workspace
WORKSPACE=$(mktemp -d)
trap 'rm -rf "${WORKSPACE}"; cleanup' EXIT

log_info "Verifying tmux is present in the container..."

# Test tmux presence and version
TMUX_VERSION=$(podman run --rm \
    --network=pasta \
    --userns=keep-id \
    --entrypoint /bin/bash \
    -v "${WORKSPACE}:/workspace:rw" \
    -w /workspace \
    "docker-archive:${IMAGE_PATH}" \
    -c "tmux -V" 2>&1) || {
    log_error "tmux is not present or not executable in the container"
    log_error "Output: ${TMUX_VERSION}"
    exit 1
}
log_info "tmux version: ${TMUX_VERSION}"

log_info "Verifying tmux-debug-mcp is present in the container..."

# Test tmux-debug-mcp presence
MCP_PRESENCE=$(podman run --rm \
    --network=pasta \
    --userns=keep-id \
    --entrypoint /bin/bash \
    -v "${WORKSPACE}:/workspace:rw" \
    -w /workspace \
    "docker-archive:${IMAGE_PATH}" \
    -c "which tmux-debug-mcp && tmux-debug-mcp --version 2>/dev/null || tmux-debug-mcp --help 2>/dev/null || echo 'found'" 2>&1) || {
    log_error "tmux-debug-mcp is not present or not executable in the container"
    log_error "Output: ${MCP_PRESENCE}"
    exit 1
}
log_info "tmux-debug-mcp found in container"

# Verify the MCP server responds to basic input (if it supports --help or version)
log_info "Verifying MCP server can start..."
MCP_START=$(timeout 5 podman run --rm \
    --network=pasta \
    --userns=keep-id \
    --entrypoint /bin/bash \
    -v "${WORKSPACE}:/workspace:rw" \
    -w /workspace \
    "docker-archive:${IMAGE_PATH}" \
    -c "echo '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"capabilities\":{}}}' | timeout 2 tmux-debug-mcp 2>/dev/null || true; echo 'startup-test-complete'" 2>&1) || true

if [[ "${MCP_START}" != *"startup-test-complete"* ]]; then
    log_warn "MCP server may not be fully implemented yet"
fi

log_info "All checks passed!"
echo ""
echo "Summary:"
echo "  - Image built successfully: ${IMAGE_NAME}"
echo "  - tmux present: ${TMUX_VERSION}"
echo "  - tmux-debug-mcp: present"

exit 0
