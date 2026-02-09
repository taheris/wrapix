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
  krunSupport ? false,
  claudeConfig,
  claudeSettings,
}:

let
  inherit (pkgs.lib) mapAttrsToList;

  notifyClient = import ../notify/client.nix { inherit pkgs; };
  ralph = import ../ralph { inherit pkgs; };

  # krun microVM support: UID spoofing library + PTY relay
  # See lib/sandbox/linux/ for source files
  libfakeuid = pkgs.stdenv.mkDerivation {
    name = "libfakeuid";
    src = ./linux/fakeuid.c;
    dontUnpack = true;
    buildPhase = "$CC -shared -fPIC -D_GNU_SOURCE -o libfakeuid.so $src -ldl";
    installPhase = "mkdir -p $out/lib && cp libfakeuid.so $out/lib/";
  };

  krunRelay = pkgs.stdenv.mkDerivation {
    name = "krun-relay";
    src = ./linux/krun-relay.c;
    dontUnpack = true;
    buildPhase = "$CC -D_GNU_SOURCE -o krun-relay $src -lutil";
    installPhase = "mkdir -p $out/bin && cp krun-relay $out/bin/";
  };

  # Nix sandbox disabled: outer container provides isolation.
  # See specs/security-review.md "Nix Sandbox Disabled" for security rationale.
  nixConfig = pkgs.writeTextDir "etc/nix/nix.conf" ''
    experimental-features = nix-command flakes
    sandbox = false
    filter-syscalls = false
  '';

  # Generate Claude JSON files from Nix attribute sets
  claudeConfigJson = pkgs.writeText "claude-config.json" (builtins.toJSON claudeConfig);
  claudeSettingsJson = pkgs.writeText "claude-settings.json" (builtins.toJSON claudeSettings);

  # Base passwd/group with fixed wrapix user (UID remapped at runtime via --userns=keep-id or setpriv)
  passwdFile = pkgs.writeTextDir "etc/passwd" ''
    root:x:0:0:root:/root:/bin/bash
    nobody:x:65534:65534:Unprivileged account:/var/empty:/bin/false
    wrapix:x:1000:1000:Wrapix Sandbox:/home/wrapix:/bin/bash
  '';

  groupFile = pkgs.writeTextDir "etc/group" ''
    root:x:0:
    nogroup:x:65534:
    wrapix:x:1000:
  '';

  # Create a merged environment with all packages for proper PATH
  allPackages = [
    pkgs.coreutils
    pkgs.bash
    pkgs.util-linux
    pkgs.iptables # Network filtering for WRAPIX_NETWORK=limit mode
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
    mkdir -p tmp home/wrapix root var/run var/cache mnt/wrapix/file mnt/wrapix/dir
    chmod 1777 tmp var/cache

    mkdir -p etc/wrapix
    echo "127.0.0.1 localhost" > etc/hosts

    cp ${entrypointSh} entrypoint.sh
    chmod +x entrypoint.sh

    ${pkgs.lib.optionalString krunSupport ''
      cp ${./linux/krun-init.sh} krun-init.sh
      chmod +x krun-init.sh
      mkdir -p lib
      cp ${libfakeuid}/lib/libfakeuid.so lib/libfakeuid.so
      cp ${krunRelay}/bin/krun-relay krun-relay
      chmod +x krun-relay
    ''}

    cp ${claudeConfigJson} etc/wrapix/claude-config.json
    cp ${claudeSettingsJson} etc/wrapix/claude-settings.json

    # Bundle ralph template for ralph-init
    cp -r ${ralph.templateDir} etc/wrapix/ralph-template

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
