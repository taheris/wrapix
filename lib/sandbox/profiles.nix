{ pkgs }:

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
  ];

  # Required mounts for ALL profiles
  baseMounts = [
    { source = "~/.claude"; dest = "~/.claude"; mode = "rw"; }
    { source = "~/.claude.json"; dest = "~/.claude.json"; mode = "rw"; }
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

  go = mkProfile {
    name = "go";
    packages = with pkgs; [ go gopls ];
    mounts = [
      { source = "~/go/pkg/mod"; dest = "~/go/pkg/mod"; mode = "ro"; optional = true; }
    ];
  };

  python = mkProfile {
    name = "python";
    packages = with pkgs; [ python3 python3Packages.pip ];
    mounts = [
      { source = "~/.cache/pip"; dest = "~/.cache/pip"; mode = "ro"; optional = true; }
      { source = "~/.cache/pypoetry"; dest = "~/.cache/pypoetry"; mode = "ro"; optional = true; }
      { source = "~/.cache/uv"; dest = "~/.cache/uv"; mode = "ro"; optional = true; }
    ];
  };

  js = mkProfile {
    name = "js";
    packages = with pkgs; [ nodejs yarn ];
    mounts = [
      { source = "~/.npm"; dest = "~/.npm"; mode = "ro"; optional = true; }
      { source = "~/.yarn"; dest = "~/.yarn"; mode = "ro"; optional = true; }
      { source = "~/.bun"; dest = "~/.bun"; mode = "ro"; optional = true; }
    ];
  };

  nix = mkProfile {
    name = "nix";
    packages = with pkgs; [ nix alejandra ];
  };

  devops = mkProfile {
    name = "devops";
    packages = with pkgs; [ docker-client kubectl terraform ];
    mounts = [
      { source = "~/.kube"; dest = "~/.kube"; mode = "ro"; optional = true; }
      { source = "~/.aws"; dest = "~/.aws"; mode = "ro"; optional = true; }
    ];
  };
}
