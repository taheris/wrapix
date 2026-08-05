{ pkgs, ... }:

let
  inherit (pkgs.lib) escapeShellArg;

  serviceScript = script: function: ''
    run_repo_script ${escapeShellArg "tests/services/${script}.sh"} ${escapeShellArg function}
  '';
in
{
  "beads.no-jsonl-staged" = serviceScript "dolt-cli" "test_no_jsonl_staged";

  "beads.shellhook-fail-loud" = serviceScript "beads-shellhook" "test_shellhook_fail_loud";

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
