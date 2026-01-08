# Build the main OCI image for wrapix sandbox
#
# This creates a layered container image with:
# - Base packages + profile-specific packages
# - Claude Code package
# - CA certificates for HTTPS
# - macOS entrypoint script for VM use
#
# Layer ordering: stable packages first, frequently-changing packages last.
# This maximizes layer cache hits across rebuilds and profiles.
{
  pkgs,
  profile,
  claudePackage,
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
  ] ++ (profile.packages or [ ]);

  extraCommands = ''
    mkdir -p tmp home root var/run
    chmod 1777 tmp

    mkdir -p etc
    echo "127.0.0.1 localhost" > etc/hosts

    cat > entrypoint.sh << 'EOF'
    #!/bin/bash
    set -euo pipefail

    # Add user entry with host UID (passwd is writable at runtime)
    echo "$HOST_USER:x:$HOST_UID:$HOST_UID::/workspace:/bin/bash" >> /etc/passwd
    echo "$HOST_USER:x:$HOST_UID:" >> /etc/group

    export HOME="/workspace"
    export USER="$HOST_USER"
    cd /workspace

    exec setpriv --reuid="$HOST_UID" --regid="$HOST_UID" --init-groups \
      claude --dangerously-skip-permissions --append-system-prompt "$WRAPIX_PROMPT"
    EOF
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
