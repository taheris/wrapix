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
{ pkgs, profile, claudePackage }:

pkgs.dockerTools.buildLayeredImage {
  name = "wrapix-${profile.name}";
  tag = "latest";
  maxLayers = 100;

  contents = [
    pkgs.dockerTools.fakeNss
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates

    # Core utilities
    pkgs.coreutils
    pkgs.bash
    pkgs.shadow  # for useradd/su

    # Claude Code
    claudePackage

    # CA certificates
    pkgs.cacert
  ] ++ (profile.packages or []);

  extraCommands = ''
    mkdir -p tmp home root var/run
    chmod 1777 tmp

    # Set up hosts file (fakeNss handles passwd/group)
    mkdir -p etc
    echo "127.0.0.1 localhost" > etc/hosts

    # Git config with SSH command that uses deploy key if DEPLOY_KEY_NAME is set
    cat > etc/gitconfig << 'GITCONFIG'
[user]
    name = Wrapix Sandbox
    email = sandbox@wrapix.dev
[core]
    sshCommand = sh -c '[ -n "$DEPLOY_KEY_NAME" ] && exec ssh -i "$HOME/.ssh/deploy_keys/$DEPLOY_KEY_NAME" -o IdentitiesOnly=yes "$@" || exec ssh "$@"' --
GITCONFIG

    # macOS entrypoint script (for VM use with user creation)
    cat > entrypoint.sh << 'MACOSENTRY'
#!/bin/bash
set -euo pipefail

# Create user matching host UID/username
useradd -u "$HOST_UID" -m "$HOST_USER" 2>/dev/null || true

# Drop privileges and run Claude Code
exec su - "$HOST_USER" -c "cd /workspace && claude"
MACOSENTRY
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
