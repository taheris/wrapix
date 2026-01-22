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
    whichQuiet
    yq
    zip
  ];

  # Required mounts for all profiles
  # Note: Host ~/.claude is NOT mounted - containers use $PROJECT_DIR/.claude instead
  # This isolates containers from host config while persisting sessions in the project
  baseMounts = [ ];

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

  # Suppress GNU which's verbose "no X in (PATH)" errors
  whichQuiet = pkgs.writeShellScriptBin "which" ''
    ${pkgs.which}/bin/which "$@" 2>/dev/null
  '';

in
{
  base = mkProfile {
    name = "base";
  };

  rust = mkProfile {
    name = "rust";

    packages = with pkgs; [
      gcc
      openssl
      openssl.dev
      pkg-config
      postgresql.lib
      rustup
    ];

    env = {
      CARGO_HOME = "/workspace/.cargo";
      LIBRARY_PATH = "${pkgs.postgresql.lib}/lib";
      OPENSSL_INCLUDE_DIR = "${pkgs.openssl.dev}/include";
      OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";
      RUSTUP_HOME = "/workspace/.rustup";
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

  python = mkProfile {
    name = "python";

    packages = with pkgs; [
      python3
      ruff
      ty
      uv
    ];

    env = {
      UV_CACHE_DIR = "/workspace/.uv-cache";
    };

    mounts = [
      {
        source = "~/.cache/uv";
        dest = "~/.cache/uv";
        mode = "ro";
        optional = true;
      }
    ];
  };
}
