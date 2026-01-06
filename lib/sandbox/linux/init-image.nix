{ pkgs }:

let
  initScript = pkgs.writeShellScriptBin "init" ''
    #!/bin/bash
    # Redirect HTTP/HTTPS to Squid
    iptables -t nat -A OUTPUT -p tcp --dport 80 -j REDIRECT --to-port 3128
    iptables -t nat -A OUTPUT -p tcp --dport 443 -j REDIRECT --to-port 3128

    # Allow localhost, established connections
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # DNS only to container's resolver
    RESOLVER=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
    iptables -A OUTPUT -p udp --dport 53 -d "$RESOLVER" -j ACCEPT
    iptables -A OUTPUT -p udp --dport 53 -j DROP

    # Block everything else
    iptables -A OUTPUT -j DROP
  '';
in
pkgs.dockerTools.buildImage {
  name = "wrapix-init";
  tag = "latest";

  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = [
      pkgs.iptables
      pkgs.bash
      pkgs.gawk
      pkgs.coreutils
      initScript
    ];
    pathsToLink = [ "/bin" ];
  };

  config = {
    Entrypoint = [ "/bin/init" ];
  };
}
