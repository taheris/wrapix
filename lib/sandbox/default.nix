{ pkgs, system }:

let
  systemPrompt = ./sandbox-prompt.txt;

  isLinux = builtins.elem system [
    "x86_64-linux"
    "aarch64-linux"
  ];
  isDarwin = system == "aarch64-darwin";

  # Import platform-specific pkgs for image building
  # On Darwin, we need x86_64-linux or aarch64-linux packages for the container image
  # This requires a Linux remote builder to be configured
  linuxPkgs =
    if isDarwin then
      import (pkgs.path) {
        system = "aarch64-linux"; # Use ARM Linux for Apple Silicon
        config.allowUnfree = true;
      }
    else
      pkgs;

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
        entrypoint = import ./linux/entrypoint.nix { inherit pkgs systemPrompt; };
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
