{ pkgs, system }:

let
  profiles = import ./profiles.nix { inherit pkgs; };
  systemPrompt = ./sandbox-prompt.txt;

  isLinux = builtins.elem system [ "x86_64-linux" "aarch64-linux" ];
  isDarwin = system == "aarch64-darwin";

  # On Linux, we can build the container image directly
  # On Darwin, cross-compilation has issues (libcap, shadow, etc.)
  # so we build the image at runtime using podman
  mkImage = profile: import ./image.nix {
    inherit pkgs profile;
    claudePackage = pkgs.claude-code;
  };

  linuxSandbox = import ./linux { inherit pkgs; };
  darwinSandbox = import ./darwin { inherit pkgs; };

  mkSandbox = { profile, deployKey ? null }:
    if isLinux then
      linuxSandbox.mkSandbox {
        inherit profile deployKey;
        profileImage = mkImage profile;
        entrypoint = import ./linux/entrypoint.nix { inherit pkgs systemPrompt; };
      }
    else if isDarwin then
      # On Darwin, we provide a stub for the image and build at runtime
      darwinSandbox.mkSandbox {
        inherit profile deployKey;
        profileImage = null;  # Built at runtime using podman
        entrypoint = import ./darwin/entrypoint.nix { inherit pkgs systemPrompt; };
      }
    else
      throw "Unsupported system: ${system}";

in {
  inherit mkSandbox profiles;
}
