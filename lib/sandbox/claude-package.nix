# Claude Code package - fetches and installs from npm
#
# To update the hash, run:
#   nix-prefetch-url "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz"
# Then convert to SRI format with:
#   nix hash to-sri --type sha256 <hash>

{ pkgs }:

let
  version = "2.0.76";
in
pkgs.stdenv.mkDerivation {
  pname = "claude-code";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
    hash = "sha256-/KOZNv+OkxDI5MaDPWRVNBuSrNkjF3hfD3c+50ORudk=";
  };

  nativeBuildInputs = [ pkgs.nodejs pkgs.gnutar pkgs.gzip ];

  unpackPhase = ''
    runHook preUnpack
    tar xzf $src --strip-components=1
    runHook postUnpack
  '';

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/lib/claude-code
    cp -r . $out/lib/claude-code/

    cat > $out/bin/claude << 'WRAPPER'
#!/usr/bin/env bash
exec ${pkgs.nodejs}/bin/node "$(dirname "$0")/../lib/claude-code/cli.js" "$@"
WRAPPER
    chmod +x $out/bin/claude

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Claude Code - Anthropic's official CLI for Claude";
    homepage = "https://www.anthropic.com";
    license = licenses.unfree;
    platforms = platforms.all;
  };
}
