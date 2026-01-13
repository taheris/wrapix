{ pkgs }:

let
  # Base packages included in all profiles
  basePackages = with pkgs; [
    bash
    beads
    coreutils
    curl
    diffutils
    fd
    file
    findutils
    gawk
    git
    gnugrep
    gnused
    gnutar
    gzip
    iproute2
    iputils
    jq
    less
    man
    nix
    openssh
    patch
    procps
    ripgrep
    rsync
    tree
    unzip
    vim
    which
    yq
    zip
  ];

  # Required mounts for all profiles
  baseMounts = [
    {
      source = "~/.claude";
      dest = "~/.claude";
      mode = "rw";
      optional = true;
    }
    {
      source = "~/.claude.json";
      dest = "~/.claude.json";
      mode = "rw";
      optional = true;
    }
    {
      source = "~/.claude.json.backup";
      dest = "~/.claude.json.backup";
      mode = "rw";
      optional = true;
    }
  ];

  # Environment variables in all profiles
  baseEnv = {
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";
    DISABLE_AUTOUPDATER = "1";
    DISABLE_ERROR_REPORTING = "1";
    DISABLE_TELEMETRY = "1";
  };

  # Helper to create a profile with base packages, mounts, and env merged in
  mkProfile =
    {
      name,
      packages ? [ ],
      env ? { },
      mounts ? [ ],
    }:
    {
      inherit name;
      packages = basePackages ++ packages;
      env = baseEnv // env;
      mounts = baseMounts ++ mounts;
    };

in
{
  base = mkProfile {
    name = "base";
  };

  rust = mkProfile {
    name = "rust";

    packages = with pkgs; [
      cargo
      gcc
      openssl
      openssl.dev
      pkg-config
      rust-analyzer
      rustc
    ];

    env = {
      CARGO_HOME = "/workspace/.cargo";
      OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
      OPENSSL_INCLUDE_DIR = "${pkgs.openssl.dev}/include";
    };

    mounts = [
      {
        source = "~/.cargo/registry";
        dest = "~/.cargo/registry";
        mode = "ro";
        optional = true;
      }
      {
        source = "~/.cargo/git";
        dest = "~/.cargo/git";
        mode = "ro";
        optional = true;
      }
    ];
  };
}
