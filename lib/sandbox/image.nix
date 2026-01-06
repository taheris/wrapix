# Build the main OCI image for wrapix sandbox
#
# This creates a layered container image with:
# - Base packages + profile-specific packages
# - Claude Code package
# - Squid proxy and its configuration
# - CA certificates for HTTPS
# - macOS entrypoint script for VM use
#
# Layer ordering: stable packages first, frequently-changing packages last.
# This maximizes layer cache hits across rebuilds and profiles.
{ pkgs, profile, claudePackage, squidConfig }:

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
    pkgs.iptables
    pkgs.shadow  # for useradd/su

    # Proxy
    pkgs.squid
    squidConfig

    # Claude Code
    claudePackage

    # CA certificates
    pkgs.cacert
  ] ++ (profile.packages or []);

  extraCommands = ''
    mkdir -p tmp home root var/run var/log/squid var/spool/squid

    # Set up hosts file (fakeNss handles passwd/group)
    mkdir -p etc
    echo "127.0.0.1 localhost" > etc/hosts

    # macOS entrypoint script (for VM use with iptables + Squid + user creation)
    cat > entrypoint.sh << 'MACOSENTRY'
#!/bin/bash
set -euo pipefail

# Setup iptables to redirect traffic through Squid proxy
iptables -t nat -A OUTPUT -p tcp --dport 80 -j REDIRECT --to-port 3128
iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-port 3128
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS only to the configured resolver
RESOLVER=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
iptables -A OUTPUT -p udp --dport 53 -d "$RESOLVER" -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j DROP
iptables -A OUTPUT -j DROP

# Start Squid proxy in background
squid -f /etc/squid/squid.conf -N &

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
      "http_proxy=http://127.0.0.1:3128"
      "https_proxy=http://127.0.0.1:3128"
      "HTTP_PROXY=http://127.0.0.1:3128"
      "HTTPS_PROXY=http://127.0.0.1:3128"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
    ];
    WorkingDir = "/workspace";
    Entrypoint = [ "/entrypoint.sh" ];
  };
}
