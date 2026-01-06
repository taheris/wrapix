# Smoke tests - pure Nix tests that don't require Podman runtime
{ pkgs, system }:

let
  inherit (builtins) elem hasAttr throw;
  inherit (pkgs) bash claude-code runCommandLocal;

  blocklist = import ../sandbox/blocklist.nix;
  squidConfig = import ../sandbox/squid.nix { inherit pkgs blocklist; };
  profiles = import ../sandbox/profiles.nix { inherit pkgs; };

  baseImage = import ../sandbox/image.nix {
    inherit pkgs squidConfig;
    profile = profiles.base;
    claudePackage = claude-code;
  };

  initImage = import ../sandbox/linux/init-image.nix { inherit pkgs; };

  sandboxLib = import ../default.nix { inherit pkgs system; };
  wrapix = sandboxLib.mkSandbox sandboxLib.profiles.base;

in {
  # Verify OCI images build and are valid tar archives
  image-builds = runCommandLocal "smoke-image-builds" {} ''
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
  blocklist = runCommandLocal "smoke-blocklist" {} ''
    echo "Verifying blocklist categories..."
    ${if hasAttr "pastebin_sites" blocklist then "" else throw "Missing pastebin_sites"}
    ${if hasAttr "file_sharing" blocklist then "" else throw "Missing file_sharing"}
    ${if hasAttr "url_shorteners" blocklist then "" else throw "Missing url_shorteners"}
    ${if hasAttr "webhook_sites" blocklist then "" else throw "Missing webhook_sites"}
    ${if hasAttr "code_execution" blocklist then "" else throw "Missing code_execution"}
    ${if hasAttr "risky_tlds" blocklist then "" else throw "Missing risky_tlds"}
    ${if hasAttr "allDomains" blocklist then "" else throw "Missing allDomains"}

    echo "Verifying expected domains are blocked..."
    ${if elem "pastebin.com" blocklist.allDomains then "" else throw "pastebin.com not blocked"}
    ${if elem "transfer.sh" blocklist.allDomains then "" else throw "transfer.sh not blocked"}
    ${if elem "webhook.site" blocklist.allDomains then "" else throw "webhook.site not blocked"}

    echo "Blocklist validation passed"
    mkdir $out
  '';

  # Verify squid config files are generated
  squid-config = runCommandLocal "smoke-squid-config" {} ''
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
  script-syntax = runCommandLocal "smoke-script-syntax" {
    nativeBuildInputs = [ bash ];
  } ''
    echo "Checking bash syntax..."
    bash -n ${wrapix}/bin/wrapix

    echo "Script syntax validation passed"
    mkdir $out
  '';
}
