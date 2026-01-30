#!/usr/bin/env bash
# Test: Build rust-debug profile, verify both rust toolchain and debug tools available
#
# This test verifies profile composition works correctly:
# 1. Build rust-debug profile (combines rust + debug profiles)
# 2. Verify rust toolchain is present (rustc, cargo, rustup)
# 3. Verify debug tools are present (tmux, tmux-debug-mcp)
# 4. Verify all base tools are still present
#
# Prerequisites:
# - nix (with flakes enabled)
# - podman
#
# Usage: ./test_profile_composition.sh

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

log_info "Building wrapix rust-debug profile image..."

# Build the rust-debug profile image (combines rust + debug)
IMAGE_PATH=$(nix build "${REPO_ROOT}#wrapix-rust-debug" --print-out-paths 2>/dev/null) || {
    log_error "Failed to build wrapix-rust-debug image"
    log_warn "The rust-debug profile may not be defined yet"
    log_warn "Profile composition requires defining profiles.rust-debug in lib/sandbox/profiles.nix"
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

# Helper function to check if a command exists in the container
check_command() {
    local cmd="$1"
    local description="${2:-$1}"

    if podman run --rm \
        --network=pasta \
        --userns=keep-id \
        --entrypoint /bin/bash \
        -v "${WORKSPACE}:/workspace:rw" \
        -w /workspace \
        "docker-archive:${IMAGE_PATH}" \
        -c "which $cmd" &>/dev/null; then
        log_info "PASS: $description is present"
        return 0
    else
        log_error "FAIL: $description is NOT present"
        FAILED=1
        return 1
    fi
}

# Helper function to run a command and check output
check_command_output() {
    local cmd="$1"
    local expected="$2"
    local description="$3"

    local output
    output=$(podman run --rm \
        --network=pasta \
        --userns=keep-id \
        --entrypoint /bin/bash \
        -v "${WORKSPACE}:/workspace:rw" \
        -w /workspace \
        "docker-archive:${IMAGE_PATH}" \
        -c "$cmd" 2>&1) || true

    if echo "$output" | grep -qi "$expected"; then
        log_info "PASS: $description"
        return 0
    else
        log_error "FAIL: $description"
        log_error "  Expected to find: $expected"
        log_error "  Got: $output"
        FAILED=1
        return 1
    fi
}

echo ""
log_info "=== Checking Rust toolchain ==="

# Check rustup (Rust toolchain manager)
check_command "rustup" "rustup (Rust toolchain manager)"

# Check rustc (Rust compiler) - may need rustup to install it first
check_command_output "rustup show 2>/dev/null || rustup --version" "rustup" "rustup is functional"

# Check cargo (Rust package manager)
check_command "cargo" "cargo (Rust package manager)" || true

# Verify CARGO_HOME and RUSTUP_HOME environment variables are set
check_command_output "echo \$CARGO_HOME" "/workspace/.cargo" "CARGO_HOME is set correctly"
check_command_output "echo \$RUSTUP_HOME" "/workspace/.rustup" "RUSTUP_HOME is set correctly"

echo ""
log_info "=== Checking debug tools ==="

# Check tmux
check_command "tmux" "tmux terminal multiplexer"
check_command_output "tmux -V" "tmux" "tmux is executable"

# Check tmux-debug-mcp
check_command "tmux-debug-mcp" "tmux-debug-mcp MCP server"

echo ""
log_info "=== Checking base profile tools ==="

# Essential base tools
check_command "git" "git"
check_command "bash" "bash"
check_command "jq" "jq"
check_command "curl" "curl"
check_command "ripgrep" "ripgrep (rg)" || check_command "rg" "ripgrep (rg)"
check_command "fd" "fd"

echo ""
log_info "=== Checking Rust development dependencies ==="

# Check OpenSSL is available (commonly needed for Rust builds)
check_command_output "echo \$OPENSSL_LIB_DIR" "openssl" "OPENSSL_LIB_DIR is set"

# Check pkg-config (needed for many native dependencies)
check_command "pkg-config" "pkg-config"

# Check gcc (needed for linking)
check_command "gcc" "gcc"

echo ""
log_info "=== Profile composition validation ==="

# Verify that profile env vars from both profiles are present
log_info "Checking that environment from both profiles is merged..."

# Create a test script to dump all relevant env vars
cat > "${WORKSPACE}/check_env.sh" << 'SCRIPT'
#!/usr/bin/env bash
echo "=== Environment Variables ==="
echo "CARGO_HOME=$CARGO_HOME"
echo "RUSTUP_HOME=$RUSTUP_HOME"
echo "OPENSSL_LIB_DIR=$OPENSSL_LIB_DIR"
echo "OPENSSL_INCLUDE_DIR=$OPENSSL_INCLUDE_DIR"
echo "PATH=$PATH"
echo ""
echo "=== Tools availability ==="
echo "rustup: $(which rustup 2>/dev/null || echo 'not found')"
echo "tmux: $(which tmux 2>/dev/null || echo 'not found')"
echo "tmux-debug-mcp: $(which tmux-debug-mcp 2>/dev/null || echo 'not found')"
echo "git: $(which git 2>/dev/null || echo 'not found')"
SCRIPT
chmod +x "${WORKSPACE}/check_env.sh"

ENV_OUTPUT=$(podman run --rm \
    --network=pasta \
    --userns=keep-id \
    --entrypoint /bin/bash \
    -v "${WORKSPACE}:/workspace:rw" \
    -w /workspace \
    "docker-archive:${IMAGE_PATH}" \
    -c "/workspace/check_env.sh" 2>&1)

echo ""
echo "Environment dump:"
echo "$ENV_OUTPUT"

echo ""
echo "========================================="
if [[ $FAILED -eq 0 ]]; then
    log_info "SUCCESS: All profile composition checks passed!"
    echo ""
    echo "Summary:"
    echo "  - rust-debug profile builds successfully"
    echo "  - Rust toolchain (rustup, cargo) available"
    echo "  - Debug tools (tmux, tmux-debug-mcp) available"
    echo "  - Base profile tools (git, jq, curl, etc.) available"
    echo "  - Environment variables from both profiles merged correctly"
    exit 0
else
    log_error "FAILED: Some profile composition checks failed"
    exit 1
fi
