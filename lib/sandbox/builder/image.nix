# Build the OCI image for wrapix-builder (persistent Linux remote builder)
#
# This creates a layered container image with:
# - nix-daemon for remote building
# - sshd for ssh-ng:// access
# - Builder user with UID 1000 for VirtioFS compatibility
#
{ pkgs }:

let
  # Packages needed for remote building
  builderPackages = with pkgs; [
    nix
    openssh
    coreutils
    bash
    gnugrep
    gnutar
    gzip
    xz
    git
    cacert
  ];

  # passwd: root, builder (UID 1000), nobody
  passwdFile = pkgs.writeTextDir "etc/passwd" ''
    root:x:0:0:root:/root:/bin/bash
    builder:x:1000:1000:Nix Builder:/home/builder:/bin/bash
    nobody:x:65534:65534:Unprivileged account:/var/empty:/bin/false
  '';

  # group: root, users (with builder), nogroup
  groupFile = pkgs.writeTextDir "etc/group" ''
    root:x:0:
    users:x:100:builder
    nogroup:x:65534:
  '';

  # sshd configuration: key-only auth, allow builder user
  sshdConfig = pkgs.writeTextDir "etc/ssh/sshd_config" ''
    Port 22
    HostKey /etc/ssh/ssh_host_ed25519_key
    AuthorizedKeysFile /home/%u/.ssh/authorized_keys
    PasswordAuthentication no
    PermitRootLogin no
    AllowUsers builder
    Subsystem sftp internal-sftp
  '';

  # Create merged environment with all packages
  builderEnv = pkgs.buildEnv {
    name = "wrapix-builder-env";
    paths = builderPackages;
    pathsToLink = [
      "/bin"
      "/share"
      "/etc"
      "/lib"
    ];
  };

in
pkgs.dockerTools.buildLayeredImage {
  name = "wrapix-builder";
  tag = "latest";
  maxLayers = 50;
  includeNixDB = true;

  contents = [
    passwdFile
    groupFile
    sshdConfig
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.binSh
    pkgs.dockerTools.caCertificates
    builderEnv
  ];

  extraCommands = ''
    mkdir -p tmp var/run var/log home/builder/.ssh run/sshd etc/ssh
    chmod 1777 tmp

    mkdir -p etc
    echo "127.0.0.1 localhost" > etc/hosts

    cp ${./entrypoint.sh} entrypoint.sh
    chmod +x entrypoint.sh

    # Fix Nix permissions for non-root users
    chmod -R a+rwX nix/store nix/var/nix

    # Pre-create Nix directory structure
    mkdir -p nix/var/nix/profiles/per-user
    mkdir -p nix/var/nix/gcroots/per-user
    mkdir -p nix/var/log/nix/drvs
    chmod 755 nix/var/nix/profiles nix/var/nix/profiles/per-user
    chmod 755 nix/var/nix/gcroots nix/var/nix/gcroots/per-user
    chmod -R a+rwX nix/var/log
  '';

  config = {
    Env = [
      "PATH=${builderEnv}/bin:/bin:/usr/bin"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    Entrypoint = [ "/entrypoint.sh" ];
    ExposedPorts = {
      "22/tcp" = { };
    };
  };
}
