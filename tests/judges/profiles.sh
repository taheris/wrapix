#!/usr/bin/env bash
# Judge rubrics for profiles.md success criteria

test_base_profile_functional() {
  judge_files "lib/sandbox/profiles.nix"
  judge_criterion "Base profile provides a functional development environment with essential tools (git, curl, basic shell utilities)"
}

test_rust_profile() {
  judge_files "lib/sandbox/profiles.nix"
  judge_criterion "Rust profile includes rustc, cargo, and can compile and run Rust projects"
}

test_python_profile() {
  judge_files "lib/sandbox/profiles.nix"
  judge_criterion "Python profile includes Python interpreter and can run Python scripts with dependencies"
}

test_derive_profile_merge() {
  judge_files "lib/sandbox/profiles.nix"
  judge_criterion "deriveProfile correctly merges packages and environment variables from base and extension profiles"
}
