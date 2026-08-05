{ pkgs, ... }:

let
  inherit (pkgs.lib) escapeShellArg;

  serviceScript = script: function: ''
    run_repo_script ${escapeShellArg "tests/services/${script}.sh"} ${escapeShellArg function}
  '';
  sandboxScript = script: function: ''
    run_repo_script ${escapeShellArg "tests/sandbox/${script}.sh"} ${escapeShellArg function}
  '';
in
{
  "beads.no-jsonl-staged" = serviceScript "dolt-cli" "test_no_jsonl_staged";

  "beads.darwin-remote-remap" = sandboxScript "entrypoint-contract" "test_darwin_bd_remote_remap";

  "beads.shellhook-darwin-runtime-fallback" =
    serviceScript "beads-shellhook" "test_darwin_shellhook_selects_podman_fallback";

  "beads.shellhook-endpoint-fail-loud" =
    serviceScript "beads-shellhook" "test_shellhook_unreachable_endpoint_fails_loud";

  "beads.shellhook-runtime-fail-loud" =
    serviceScript "beads-shellhook" "test_shellhook_missing_runtime_fails_loud";

  "beads.tracked-files" = ''
    local actual
    local expected
    local root
    root="$(repo_root)"
    expected="$(printf '%s\n' '.beads/.gitignore' '.beads/config.yaml' '.beads/metadata.json')"
    actual="$(git -C "$root" ls-files -- .beads)"

    if [[ "$actual" != "$expected" ]]; then
      printf 'Expected tracked .beads files:\n%s\n' "$expected" >&2
      printf 'Actual tracked .beads files:\n%s\n' "$actual" >&2
      return 1
    fi
  '';
}
