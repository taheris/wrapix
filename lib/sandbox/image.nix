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
  gitConfig = pkgs.writeTextDir "etc/gitconfig" ''
    [user]
        name = Wrapix Sandbox
        email = sandbox@wrapix.dev
    [core]
        sshCommand = sh -c '[ -n "$DEPLOY_KEY_NAME" ] && exec ssh -i "$HOME/.ssh/deploy_keys/$DEPLOY_KEY_NAME" -o IdentitiesOnly=yes "$@" || exec ssh "$@"' --
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
    pkgs.coreutils
    pkgs.bash
    pkgs.util-linux # for setpriv
    claudePackage
    pkgs.cacert
    gitConfig
  ]
  ++ (profile.packages or [ ]);

  extraCommands = ''
    mkdir -p tmp home root var/run mnt/wrapix/file-mount
    chmod 1777 tmp

    mkdir -p etc
    echo "127.0.0.1 localhost" > etc/hosts

    cp ${entrypointScript} entrypoint.sh
    chmod +x entrypoint.sh
  '';

  config = {
    Env = [
      "PATH=/bin:/usr/bin"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    WorkingDir = "/workspace";
    Entrypoint = [ "/entrypoint.sh" ];
  };
}
