{
  pkgs,
  system,
  linuxPkgs,
}:

let
  isLinux = builtins.elem system [
    "x86_64-linux"
    "aarch64-linux"
  ];
  isDarwin = system == "aarch64-darwin";

  # Profiles must use Linux packages (they contain Linux-only tools like iproute2)
  profiles = import ./profiles.nix { pkgs = linuxPkgs; };

  # Build the container image using Linux packages
  # On Darwin, this will use a remote Linux builder if configured
  mkImage =
    { profile, entrypointScript }:
    import ./image.nix {
      pkgs = linuxPkgs;
      inherit profile entrypointScript;
      claudePackage = linuxPkgs.claude-code;
    };

  linuxSandbox = import ./linux { inherit pkgs; };
  darwinSandbox = import ./darwin { inherit pkgs linuxPkgs; };

  mkSandbox =
    {
      profile,
      deployKey ? null,
    }:
    if isLinux then
      linuxSandbox.mkSandbox {
        inherit profile deployKey;
        profileImage = mkImage {
          inherit profile;
          entrypointScript = ./linux/entrypoint.sh;
        };
      }
    else if isDarwin then
      darwinSandbox.mkSandbox {
        inherit profile deployKey;
        profileImage = mkImage {
          inherit profile;
          entrypointScript = ./darwin/entrypoint.sh;
        };
      }
    else
      throw "Unsupported system: ${system}";

in
{
  inherit mkSandbox profiles;
}
