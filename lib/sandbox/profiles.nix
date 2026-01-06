{ pkgs, beadsPackage }:

let
  # Base packages included in ALL profiles
  basePackages = with pkgs; [
    bash
    coreutils
    findutils
    git
    jujutsu
    ripgrep
    fd
    tree
    less
    gnugrep
    gnused
    gawk
    jq
    yq
    gnutar
    gzip
    zip
    unzip
    vim
    man
    file
    which
    patch
    diffutils
    procps
    rsync
    beadsPackage
  ];

  # Required mounts for ALL profiles
  baseMounts = [
    { source = "~/.claude"; dest = "~/.claude"; mode = "rw"; optional = true; }
    { source = "~/.claude.json"; dest = "~/.claude.json"; mode = "rw"; optional = true; }
    { source = "~/.claude.json.backup"; dest = "~/.claude.json.backup"; mode = "rw"; optional = true; }
    { source = "~/.config/git"; dest = "~/.config/git"; mode = "ro"; }
  ];

  # Environment variables for ALL profiles
  baseEnv = {
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    DISABLE_AUTOUPDATER = "1";
    DISABLE_ERROR_REPORTING = "1";
    DISABLE_TELEMETRY = "1";
  };

  # Helper to create a profile with base packages, mounts, and env merged in
  mkProfile = { name, packages ? [], mounts ? [], env ? {}, customPrompt ? null }:
    {
      inherit name;
      packages = basePackages ++ packages;
      mounts = baseMounts ++ mounts;
      env = baseEnv // env;
    } // (if customPrompt != null then { inherit customPrompt; } else {});

in {
  base = mkProfile {
    name = "base";
    packages = with pkgs; [ ];
  };

  rust = mkProfile {
    name = "rust";
    packages = with pkgs; [ rustc cargo rust-analyzer ];
    mounts = [
      { source = "~/.cargo/registry"; dest = "~/.cargo/registry"; mode = "ro"; optional = true; }
      { source = "~/.cargo/git"; dest = "~/.cargo/git"; mode = "ro"; optional = true; }
    ];
    env = { CARGO_HOME = "/tmp/cargo"; };
  };

}
