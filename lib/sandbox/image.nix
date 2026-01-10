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
  claudePackage,
  entrypointScript,
}:

let
  nixConfig = pkgs.writeTextDir "etc/nix/nix.conf" ''
    experimental-features = nix-command flakes
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
    claudePackage
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
    mkdir -p tmp home root var/run mnt/wrapix/file mnt/wrapix/dir
    chmod 1777 tmp

    mkdir -p etc
    echo "127.0.0.1 localhost" > etc/hosts

    cp ${entrypointScript} entrypoint.sh
    chmod +x entrypoint.sh
  '';

  config = {
    Env = [
      "PATH=${profileEnv}/bin:/bin:/usr/bin"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "GIT_AUTHOR_NAME=Wrapix Sandbox"
      "GIT_AUTHOR_EMAIL=sandbox@wrapix.dev"
      "GIT_COMMITTER_NAME=Wrapix Sandbox"
      "GIT_COMMITTER_EMAIL=sandbox@wrapix.dev"
    ];
    WorkingDir = "/workspace";
    Entrypoint = [ "/entrypoint.sh" ];
  };
}
