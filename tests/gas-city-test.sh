#!/usr/bin/env bash
# Gas City tests — verifies gas-city spec success criteria
# Run: bash tests/gas-city-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Track test results
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
  echo "  PASS: $1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
  echo "  FAIL: $1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
  TESTS_RUN=$((TESTS_RUN + 1))
}

skip() {
  echo "  SKIP: $1"
  ((TESTS_RUN++))
}

# --- Tests ---

test_gc_package_available() {
  echo "Test: gc package is exposed in flake outputs"
  if nix eval --json .#packages.x86_64-linux.gc.name 2>/dev/null | grep -q '"gc-'; then
    pass "gc package evaluates for x86_64-linux"
  else
    fail "gc package does not evaluate for x86_64-linux"
  fi
}

test_gc_binary_runs() {
  echo "Test: gc binary executes"
  if nix build .#gc --no-link --print-out-paths 2>/dev/null; then
    local gc_path
    gc_path="$(nix build .#gc --no-link --print-out-paths 2>/dev/null)"
    if "$gc_path/bin/gc" version 2>/dev/null | grep -qE '.+'; then
      pass "gc binary runs and reports version"
    else
      fail "gc binary did not return version"
    fi
  else
    fail "gc package failed to build"
  fi
}

test_gascity_input_pinned() {
  echo "Test: gascity input is pinned in flake.lock"
  if [[ -f "$REPO_ROOT/flake.lock" ]] && grep -q '"gascity"' "$REPO_ROOT/flake.lock"; then
    pass "gascity input exists in flake.lock"
  else
    fail "gascity input not found in flake.lock"
  fi
}

test_mkcity_minimal_eval() {
  echo "Test: mkCity evaluates with minimal config (services.api.package = myApp)"
  if nix eval --impure --json --expr '
    let
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      nixpkgsInfo = flakeLock.nodes.nixpkgs.locked;
      pkgs = import (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsInfo.rev}.tar.gz";
        sha256 = nixpkgsInfo.narHash;
      }) { system = "x86_64-linux"; config.allowUnfree = true; };
      linuxPkgs = pkgs;
      sandbox = import ./lib/sandbox { inherit pkgs linuxPkgs; system = "x86_64-linux"; };
      city = import ./lib/city { inherit pkgs linuxPkgs; inherit (sandbox) mkSandbox profiles; };
      result = city.mkCity { services.api.package = pkgs.hello; secrets.claude = "ANTHROPIC_API_KEY"; };
    in builtins.attrNames result
  ' 2>/dev/null | grep -q '"config"'; then
    pass "mkCity evaluates with minimal config"
  else
    fail "mkCity does not evaluate with minimal config"
  fi
}

test_city_toml_valid() {
  echo "Test: Generated city.toml is valid and references wrapix provider"
  local config
  config=$(nix eval --impure --json --expr '
    let
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      nixpkgsInfo = flakeLock.nodes.nixpkgs.locked;
      pkgs = import (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsInfo.rev}.tar.gz";
        sha256 = nixpkgsInfo.narHash;
      }) { system = "x86_64-linux"; config.allowUnfree = true; };
      linuxPkgs = pkgs;
      sandbox = import ./lib/sandbox { inherit pkgs linuxPkgs; system = "x86_64-linux"; };
      city = import ./lib/city { inherit pkgs linuxPkgs; inherit (sandbox) mkSandbox profiles; };
      result = city.mkCity { services.api.package = pkgs.hello; secrets.claude = "ANTHROPIC_API_KEY"; };
    in result.configAttrs
  ' 2>/dev/null)
  if echo "$config" | grep -q '"provider":"exec:/nix/store/'; then
    pass "city.toml references exec:<path> provider"
  else
    fail "city.toml missing exec: provider reference"
  fi
}

test_service_image_build() {
  echo "Test: Service packages are built into OCI images via dockerTools.buildLayeredImage"
  local img_name
  img_name=$(nix eval --impure --json --expr '
    let
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      nixpkgsInfo = flakeLock.nodes.nixpkgs.locked;
      pkgs = import (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsInfo.rev}.tar.gz";
        sha256 = nixpkgsInfo.narHash;
      }) { system = "x86_64-linux"; config.allowUnfree = true; };
      linuxPkgs = pkgs;
      sandbox = import ./lib/sandbox { inherit pkgs linuxPkgs; system = "x86_64-linux"; };
      city = import ./lib/city { inherit pkgs linuxPkgs; inherit (sandbox) mkSandbox profiles; };
      result = city.mkCity { services.api.package = pkgs.hello; secrets.claude = "ANTHROPIC_API_KEY"; };
    in result.serviceImages.api.name
  ' 2>/dev/null)
  if echo "$img_name" | grep -q 'wrapix-svc-api'; then
    pass "service image named wrapix-svc-api"
  else
    fail "service image not created correctly: $img_name"
  fi
}

test_secrets_runtime_only() {
  echo "Test: Secrets are classified for runtime injection, not baked into images"
  local secrets
  secrets=$(nix eval --impure --json --expr '
    let
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      nixpkgsInfo = flakeLock.nodes.nixpkgs.locked;
      pkgs = import (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsInfo.rev}.tar.gz";
        sha256 = nixpkgsInfo.narHash;
      }) { system = "x86_64-linux"; config.allowUnfree = true; };
      linuxPkgs = pkgs;
      sandbox = import ./lib/sandbox { inherit pkgs linuxPkgs; system = "x86_64-linux"; };
      city = import ./lib/city { inherit pkgs linuxPkgs; inherit (sandbox) mkSandbox profiles; };
      result = city.mkCity {
        services.api.package = pkgs.hello;
        secrets.claude = "ANTHROPIC_API_KEY";
        secrets.deployKey = "/run/secrets/deploy-key";
      };
    in result.classifiedSecrets
  ' 2>/dev/null)
  if echo "$secrets" | grep -q '"type":"env"' && echo "$secrets" | grep -q '"type":"file"'; then
    pass "secrets classified as env/file for runtime injection"
  else
    fail "secrets classification incorrect: $secrets"
  fi
}

test_role_formulas() {
  echo "Test: mkCity exposes agent sandbox for role containers"
  local has_sandbox
  has_sandbox=$(nix eval --impure --json --expr '
    let
      flakeLock = builtins.fromJSON (builtins.readFile ./flake.lock);
      nixpkgsInfo = flakeLock.nodes.nixpkgs.locked;
      pkgs = import (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsInfo.rev}.tar.gz";
        sha256 = nixpkgsInfo.narHash;
      }) { system = "x86_64-linux"; config.allowUnfree = true; };
      linuxPkgs = pkgs;
      sandbox = import ./lib/sandbox { inherit pkgs linuxPkgs; system = "x86_64-linux"; };
      city = import ./lib/city { inherit pkgs linuxPkgs; inherit (sandbox) mkSandbox profiles; };
      result = city.mkCity { services = {}; };
    in builtins.hasAttr "package" result.agentSandbox
  ' 2>/dev/null)
  if [[ "$has_sandbox" == "true" ]]; then
    pass "mkCity exposes agentSandbox with package attribute"
  else
    fail "mkCity agentSandbox missing package attribute"
  fi
}

# --- Run ---

echo "=== Gas City Tests ==="
test_gc_package_available
test_gc_binary_runs
test_gascity_input_pinned
test_mkcity_minimal_eval
test_city_toml_valid
test_service_image_build
test_secrets_runtime_only
test_role_formulas

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
