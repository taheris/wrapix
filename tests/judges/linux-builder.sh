#!/usr/bin/env bash
# Judge rubrics for linux-builder.md success criteria

test_ssh_key_auth() {
  judge_files "lib/builder/default.nix"
  judge_criterion "SSH connection to the builder uses key-based authentication (no passwords) for security"
}

test_nix_darwin_config() {
  judge_files "lib/builder/default.nix"
  judge_criterion "nix-darwin configuration enables the builder as a permanent setup that persists across reboots"
}
