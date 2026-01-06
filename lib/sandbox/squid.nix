# Squid proxy configuration generator
# Generates transparent proxy config with domain blocking

{ pkgs, blocklist }:

let
  # Generate blocklist.acl content (one domain per line)
  blocklistAcl = pkgs.lib.concatStringsSep "\n" blocklist.allDomains;

  # Generate tld-blocklist.acl content (TLDs prefixed with dot)
  tldBlocklistAcl = pkgs.lib.concatStringsSep "\n" (
    map (tld: ".${tld}") blocklist.risky_tlds
  );

  # Squid configuration
  squidConf = ''
    # Transparent proxy configuration
    http_port 3128 transparent

    # ACL definitions
    acl blocked_domains dstdomain "/etc/squid/blocklist.acl"
    acl blocked_tlds dstdomain "/etc/squid/tld-blocklist.acl"
    acl to_ipaddress url_regex ^https?://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+
    acl websocket_upgrade req_header Upgrade -i websocket

    # Access rules - deny risky traffic, allow everything else
    http_access deny blocked_domains
    http_access deny blocked_tlds
    http_access deny to_ipaddress
    http_access deny websocket_upgrade
    http_access allow all

    # JSON logging format for structured log analysis
    logformat json {"timestamp":"%tl","url":"%ru","status":%>Hs,"action":"%Ss"}
    access_log stdio:/dev/stdout json
  '';

in
pkgs.symlinkJoin {
  name = "squid-config";
  paths = [
    (pkgs.writeTextDir "etc/squid/squid.conf" squidConf)
    (pkgs.writeTextDir "etc/squid/blocklist.acl" blocklistAcl)
    (pkgs.writeTextDir "etc/squid/tld-blocklist.acl" tldBlocklistAcl)
  ];
}
