# Gas City integration test — validates gc accepts our config and starts
#
# Requires KVM. Run via: nix build .#checks.x86_64-linux.gc-integration
# Or via prek: git hook run manual (gc-integration hook)
{ pkgs }:

let
  wrapix = import ../lib {
    inherit pkgs;
    inherit (pkgs.stdenv.hostPlatform) system;
    linuxPkgs = pkgs;
  };

  city = wrapix.mkCity {
    name = "test";
    profile = wrapix.profiles.base;
  };

  commonModule =
    { pkgs, ... }:
    {
      virtualisation = {
        memorySize = 1024;
        diskSize = 2048;
        cores = 2;
      };

      environment.systemPackages = [
        pkgs.gc
        pkgs.git
      ];

      users.users.testuser = {
        isNormalUser = true;
        uid = 1000;
      };
    };

in
{
  # Validate gc accepts the generated city.toml
  gc-config-vm = pkgs.testers.nixosTest {
    name = "gc-config-vm";

    nodes.machine =
      { ... }:
      {
        imports = [ commonModule ];
      };

    testScript = ''
      machine.wait_for_unit("multi-user.target")

      # Set up a workspace with our generated config
      machine.succeed("mkdir -p /tmp/workspace/.gc/formulas")
      machine.succeed("cp ${city.config} /tmp/workspace/city.toml")
      machine.succeed(
        "for f in ${city.formulas}/*.formula.toml; do "
        "cp \"$f\" /tmp/workspace/.gc/formulas/; done"
      )

      # gc config show --validate must succeed
      result = machine.succeed(
        "cd /tmp/workspace && gc config show --validate 2>&1"
      )
      assert "valid" in result.lower(), f"gc config validation failed: {result}"

      # gc config show should dump parseable TOML
      config_output = machine.succeed(
        "cd /tmp/workspace && gc config show 2>&1"
      )
      assert "workspace" in config_output, f"Missing [workspace] in config: {config_output}"
      assert "agent" in config_output, f"Missing [[agent]] in config: {config_output}"
    '';
  };
}
