# Build the main OCI image for wrapix sandbox
#
# This creates a layered container image with:
# - Base packages + profile-specific packages
# - Claude Code package
# - CA certificates for HTTPS
# - Platform-specific entrypoint script
#
# Layer ordering: stable packages first, frequently-changing packages last.
# This maximizes layer cache hits across rebuilds and profiles.
{
  pkgs,
  profile,
  entrypointPkg,
  entrypointSh,
  claudeConfigInit,
}:

let
  inherit (pkgs.lib) mapAttrsToList;

  notifyClient = import ../notify/client.nix { inherit pkgs; };

  nixConfig = pkgs.writeTextDir "etc/nix/nix.conf" ''
    experimental-features = nix-command flakes
    sandbox = false
    filter-syscalls = false
  '';

  # Base passwd/group (user added at runtime with host UID)
  passwdFile = pkgs.writeTextDir "etc/passwd" ''
    root:x:0:0:root:/root:/bin/bash
    nobody:x:65534:65534:Unprivileged account:/var/empty:/bin/false
  '';

  groupFile = pkgs.writeTextDir "etc/group" ''
    root:x:0:
    nogroup:x:65534:
  '';

  # Create a merged environment with all packages for proper PATH
  allPackages = [
    pkgs.coreutils
    pkgs.bash
    pkgs.util-linux
    entrypointPkg
    notifyClient
  ]
  ++ (profile.packages or [ ]);

  profileEnv = pkgs.buildEnv {
    name = "wrapix-profile-env";
    paths = allPackages;
    pathsToLink = [
      "/bin"
      "/share"
      "/etc"
      "/lib"
    ];
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "wrapix-${profile.name}";
  tag = "latest";
  maxLayers = 100;
  includeNixDB = true;

  contents = [
    passwdFile
    groupFile
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates
    pkgs.cacert
    nixConfig
    profileEnv
  ];

  extraCommands = ''
    mkdir -p tmp home root var/run var/cache mnt/wrapix/file mnt/wrapix/dir
    chmod 1777 tmp var/cache

    mkdir -p etc/wrapix
    echo "127.0.0.1 localhost" > etc/hosts

    cp ${entrypointSh} entrypoint.sh
    chmod +x entrypoint.sh

    cp ${claudeConfigInit} etc/wrapix/init-claude-config.sh
    chmod +x etc/wrapix/init-claude-config.sh

    # Fix Nix permissions for non-root users
    # (includeNixDB creates files owned by root)
    # Store must be writable to add new paths and create lock files
    chmod -R a+rwX nix/store nix/var/nix

    # Pre-create directory structure Nix expects with correct permissions
    # This prevents Nix from trying to chmod directories it doesn't own
    mkdir -p nix/var/nix/profiles/per-user
    mkdir -p nix/var/nix/gcroots/per-user
    mkdir -p nix/var/nix/gcroots/auto
    mkdir -p nix/var/log/nix/drvs
    chmod 755 nix/var/nix/profiles nix/var/nix/profiles/per-user
    chmod 755 nix/var/nix/gcroots nix/var/nix/gcroots/per-user
    chmod 1777 nix/var/nix/gcroots/auto
    chmod -R a+rwX nix/var/log
  '';

  config = {
    Env = [
      # GIT_AUTHOR_*/GIT_COMMITTER_* set at runtime by launcher (from host git config)
      "PATH=${profileEnv}/bin:/bin:/usr/bin"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "XDG_CACHE_HOME=/var/cache"
    ]
    ++ (mapAttrsToList (name: value: "${name}=${value}") (profile.env or { }));
    WorkingDir = "/workspace";
    Entrypoint = [ "/entrypoint.sh" ];
  };
}
