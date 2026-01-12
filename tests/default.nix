# Test entry point - exports all checks for flake
{
  pkgs,
  system,
  src,
}:

let
  inherit (builtins) elem pathExists;

  isLinux = elem system [
    "x86_64-linux"
    "aarch64-linux"
  ];

  # Check if KVM is available (for VM integration tests)
  # This is impure - requires `nix flake check --impure`
  hasKvm = pathExists "/dev/kvm";

  # Smoke tests run on all platforms
  smokeTests = import ./smoke.nix { inherit pkgs system; };

  # Darwin mount tests run on all platforms (test logic, not VM)
  darwinMountTests = import ./darwin-mounts.nix { inherit pkgs system; };

  # Darwin network tests run on all platforms (test logic, not VM)
  darwinNetworkTests = import ./darwin-network.nix { inherit pkgs system; };

  # Integration tests require NixOS VM (Linux with KVM only)
  # Skip when KVM unavailable (e.g., inside containers)
  integrationTests =
    if isLinux && hasKvm then import ./integration.nix { inherit pkgs system; } else { };

  # Lint checks run on all platforms
  lintChecks = import ./lint.nix { inherit pkgs src; };

in
{
  checks = smokeTests // darwinMountTests // darwinNetworkTests // integrationTests // lintChecks;
  inherit
    smokeTests
    darwinMountTests
    darwinNetworkTests
    integrationTests
    lintChecks
    ;
}
