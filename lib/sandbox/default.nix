{
  pkgs,
  system,
  linuxPkgs,
}:

let
  inherit (builtins) elem;

  isDarwin = system == "aarch64-darwin";
  isLinux = elem system [
    "aarch64-linux"
    "x86_64-linux"
  ];

  darwinSandbox = import ./darwin { inherit pkgs; };
  linuxSandbox = import ./linux { inherit pkgs; };

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
