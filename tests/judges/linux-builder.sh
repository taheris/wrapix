#!/usr/bin/env bash
# Judge rubrics for linux-builder.md success criteria

test_ssh_key_auth() {
  judge_files "lib/builder/default.nix"
  judge_criterion "SSH connection to the builder uses key-based authentication (no passwords) for security"
}

test_nix_darwin_config() {
  judge_files "lib/builder/default.nix"
  judge_criterion "The code provides a 'config' subcommand that prints a nix-darwin configuration snippet for the user to manually add to their nix-darwin config. A full nix-darwin module that automatically enables permanent setup is NOT yet implemented — only the helper snippet printer exists. PASS if the config subcommand exists and prints a nix-darwin snippet; the absence of a full nix-darwin module is expected."
}
