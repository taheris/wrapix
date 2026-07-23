#!/usr/bin/env bash
set -euo pipefail

PLAYWRIGHT_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYWRIGHT_REPO_ROOT="${PLAYWRIGHT_REPO_ROOT:-$(cd "${PLAYWRIGHT_HELPER_DIR}/../../.." && pwd)}"
PLAYWRIGHT_SYSTEM="${PLAYWRIGHT_SYSTEM:-$(nix eval --raw --impure --expr 'builtins.currentSystem')}"
PLAYWRIGHT_EVAL_NIX="${PLAYWRIGHT_REPO_ROOT}/tests/mcp/playwright/eval.nix"
PLAYWRIGHT_SERVER_CONFIG_FILE="${PLAYWRIGHT_SERVER_CONFIG_FILE:-}"

playwright_require_linux() {
    if [[ "$PLAYWRIGHT_SYSTEM" != *-linux ]]; then
        printf 'SKIP: Playwright MCP host verifier requires Linux-compatible browser binaries.\n' >&2
        exit 77
    fi
}

playwright_eval_raw() {
    local mode="$1"
    shift

    nix-instantiate --eval --strict --json "$PLAYWRIGHT_EVAL_NIX" \
        --argstr repoRoot "$PLAYWRIGHT_REPO_ROOT" \
        --argstr system "$PLAYWRIGHT_SYSTEM" \
        --argstr mode "$mode" \
        "$@" \
        | jq -r .
}

playwright_build_mode() {
    local mode="$1"
    shift

    nix build --no-link --print-out-paths --impure --no-warn-dirty --file "$PLAYWRIGHT_EVAL_NIX" \
        --argstr repoRoot "$PLAYWRIGHT_REPO_ROOT" \
        --argstr system "$PLAYWRIGHT_SYSTEM" \
        --argstr mode "$mode" \
        "$@"
}

playwright_build_package() {
    local package_name="$1"
    shift

    playwright_build_mode package --argstr packageName "$package_name" "$@"
}

playwright_config_path() {
    local user_data_dir="$1"
    local headless="${2:-true}"
    local width="${3:-1280}"
    local height="${4:-720}"
    local config_json="{}"
    local config_path
    if [[ $# -ge 5 ]]; then
        config_json="$5"
    fi

    config_path=$(playwright_eval_raw config-path \
        --argstr userDataDir "$user_data_dir" \
        --argstr headless "$headless" \
        --argstr width "$width" \
        --argstr height "$height" \
        --argstr configJson "$config_json") || return 1
    playwright_build_mode config-realizer \
        --argstr userDataDir "$user_data_dir" \
        --argstr headless "$headless" \
        --argstr width "$width" \
        --argstr height "$height" \
        --argstr configJson "$config_json" >/dev/null || return 1
    printf '%s\n' "$config_path"
}

playwright_server_args() {
    local user_data_dir="$1"
    local headless="${2:-true}"
    local width="${3:-1280}"
    local height="${4:-720}"
    local config_json="{}"
    local args_json
    if [[ $# -ge 5 ]]; then
        config_json="$5"
    fi

    if [[ -n "$PLAYWRIGHT_SERVER_CONFIG_FILE" ]]; then
        jq -er '.mcpServers.playwright.args[]' "$PLAYWRIGHT_SERVER_CONFIG_FILE"
        return
    fi

    playwright_config_path "$user_data_dir" "$headless" "$width" "$height" "$config_json" >/dev/null || return 1
    args_json=$(playwright_eval_raw server-args-json \
        --argstr userDataDir "$user_data_dir" \
        --argstr headless "$headless" \
        --argstr width "$width" \
        --argstr height "$height" \
        --argstr configJson "$config_json") || return 1
    jq -r '.[]' <<<"$args_json"
}

playwright_server_env_json() {
    local user_data_dir="$1"
    local headless="${2:-true}"
    local width="${3:-1280}"
    local height="${4:-720}"
    local config_json="{}"
    if [[ $# -ge 5 ]]; then
        config_json="$5"
    fi

    if [[ -n "$PLAYWRIGHT_SERVER_CONFIG_FILE" ]]; then
        jq -ec '.mcpServers.playwright.env' "$PLAYWRIGHT_SERVER_CONFIG_FILE"
        return
    fi

    playwright_eval_raw server-env-json \
        --argstr userDataDir "$user_data_dir" \
        --argstr headless "$headless" \
        --argstr width "$width" \
        --argstr height "$height" \
        --argstr configJson "$config_json"
}

playwright_server_env() {
    local user_data_dir="$1"
    local headless="${2:-true}"
    local width="${3:-1280}"
    local height="${4:-720}"
    local config_json="{}"
    local env_json
    if [[ $# -ge 5 ]]; then
        config_json="$5"
    fi

    env_json=$(playwright_server_env_json "$user_data_dir" "$headless" "$width" "$height" "$config_json") || return 1
    jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$env_json"
}

playwright_find_mcp() {
    local package_path
    local mcp_bin

    if [[ -n "$PLAYWRIGHT_SERVER_CONFIG_FILE" ]]; then
        mcp_bin=$(jq -er '.mcpServers.playwright.command' "$PLAYWRIGHT_SERVER_CONFIG_FILE") || return 1
        mcp_bin=$(command -v "$mcp_bin") || return 1
    else
        package_path=$(playwright_build_package playwright-mcp) || return 1
        mcp_bin="${package_path}/bin/playwright-mcp"
    fi
    if [[ ! -x "$mcp_bin" ]]; then
        printf 'playwright-mcp binary is not executable: %s\n' "$mcp_bin" >&2
        return 1
    fi
    printf '%s\n' "$mcp_bin"
}

playwright_find_python() {
    local python_bin

    if python_bin=$(command -v python3); then
        printf '%s\n' "$python_bin"
        return 0
    fi

    local package_path
    package_path=$(nix build 'nixpkgs#python3' --no-link --print-out-paths) || return 1
    printf '%s/bin/python3\n' "$package_path"
}
