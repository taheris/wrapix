{ pkgs, system }:

let
  profiles = import ./profiles.nix { inherit pkgs; };
  blocklist = import ./blocklist.nix;
  claudePackage = pkgs.claude-code;
  squidConfig = import ./squid.nix { inherit pkgs blocklist; };
  systemPrompt = ./sandbox-prompt.txt;

  mkImage = profile: import ./image.nix {
    inherit pkgs profile claudePackage squidConfig;
  };

  isLinux = builtins.elem system [ "x86_64-linux" "aarch64-linux" ];
  isDarwin = system == "aarch64-darwin";

  linuxSandbox = import ./linux {
    inherit pkgs;
    initImage = import ./linux/init-image.nix { inherit pkgs; };
  };

  # darwinSandbox = import ./darwin { inherit pkgs; };  # Phase 2

  mkSandbox = profile:
    if isLinux then
      linuxSandbox.mkSandbox {
        inherit profile;
        profileImage = mkImage profile;
        entrypoint = import ./linux/entrypoint.nix { inherit pkgs systemPrompt; };
      }
    else if isDarwin then
      throw "macOS support coming in Phase 2"
    else
      throw "Unsupported system: ${system}";

in {
  inherit mkSandbox profiles;
}
