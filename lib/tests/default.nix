# Test entry point - exports all checks for flake
{ pkgs, system }:

let
  isLinux = builtins.elem system [ "x86_64-linux" "aarch64-linux" ];

  # Smoke tests run on all platforms
  smokeTests = import ./smoke.nix { inherit pkgs system; };

  # Integration tests require NixOS VM (Linux only with KVM)
  integrationTests = if isLinux then import ./integration.nix { inherit pkgs system; } else {};

in {
  checks = smokeTests // integrationTests;
  inherit smokeTests integrationTests;
}
