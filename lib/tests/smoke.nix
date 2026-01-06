# Smoke tests - pure Nix tests that don't require Podman runtime
{ pkgs, system }:

let
  blocklist = import ../sandbox/blocklist.nix;
  squidConfig = import ../sandbox/squid.nix { inherit pkgs blocklist; };
  profiles = import ../sandbox/profiles.nix { inherit pkgs; };
  claudePackage = pkgs.claude-code;

  baseImage = import ../sandbox/image.nix {
    inherit pkgs claudePackage squidConfig;
    profile = profiles.base;
  };

  initImage = import ../sandbox/linux/init-image.nix { inherit pkgs; };

  sandboxLib = import ../default.nix { inherit pkgs system; };
  wrapix = sandboxLib.mkSandbox sandboxLib.profiles.base;

in {
  # Verify OCI images build and are valid tar archives
  image-builds = pkgs.runCommandLocal "smoke-image-builds" {} ''
    echo "Checking base image..."
    test -f ${baseImage}
    tar -tf ${baseImage} >/dev/null

    echo "Checking init image..."
    test -f ${initImage}
    tar -tf ${initImage} >/dev/null

    echo "All images built successfully"
    mkdir $out
  '';

  # Verify blocklist structure is valid
  blocklist = pkgs.runCommandLocal "smoke-blocklist" {} ''
    echo "Verifying blocklist categories..."
    ${if builtins.hasAttr "pastebin_sites" blocklist then "" else builtins.throw "Missing pastebin_sites"}
    ${if builtins.hasAttr "file_sharing" blocklist then "" else builtins.throw "Missing file_sharing"}
    ${if builtins.hasAttr "url_shorteners" blocklist then "" else builtins.throw "Missing url_shorteners"}
    ${if builtins.hasAttr "webhook_sites" blocklist then "" else builtins.throw "Missing webhook_sites"}
    ${if builtins.hasAttr "code_execution" blocklist then "" else builtins.throw "Missing code_execution"}
    ${if builtins.hasAttr "risky_tlds" blocklist then "" else builtins.throw "Missing risky_tlds"}
    ${if builtins.hasAttr "allDomains" blocklist then "" else builtins.throw "Missing allDomains"}

    echo "Verifying expected domains are blocked..."
    ${if builtins.elem "pastebin.com" blocklist.allDomains then "" else builtins.throw "pastebin.com not blocked"}
    ${if builtins.elem "transfer.sh" blocklist.allDomains then "" else builtins.throw "transfer.sh not blocked"}
    ${if builtins.elem "webhook.site" blocklist.allDomains then "" else builtins.throw "webhook.site not blocked"}

    echo "Blocklist validation passed"
    mkdir $out
  '';

  # Verify squid config files are generated
  squid-config = pkgs.runCommandLocal "smoke-squid-config" {} ''
    echo "Checking squid config files..."
    test -f ${squidConfig}/etc/squid/squid.conf
    test -f ${squidConfig}/etc/squid/blocklist.acl
    test -f ${squidConfig}/etc/squid/tld-blocklist.acl

    echo "Verifying blocklist.acl has content..."
    test -s ${squidConfig}/etc/squid/blocklist.acl

    echo "Verifying tld-blocklist.acl has TLDs..."
    grep -q "\.tk" ${squidConfig}/etc/squid/tld-blocklist.acl

    echo "Squid config validation passed"
    mkdir $out
  '';

  # Verify wrapix script has valid bash syntax
  script-syntax = pkgs.runCommandLocal "smoke-script-syntax" {
    nativeBuildInputs = [ pkgs.bash ];
  } ''
    echo "Checking bash syntax..."
    bash -n ${wrapix}/bin/wrapix

    echo "Script syntax validation passed"
    mkdir $out
  '';
}
