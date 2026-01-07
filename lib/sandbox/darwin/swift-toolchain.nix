# Swift 6.x toolchain for macOS (Apple Silicon)
#
# Downloads the official Swift release from swift.org and extracts the toolchain.
# This provides Swift 6.x for building wrapix-runner, which uses the Containerization
# framework available in macOS 26+.
#
# Based on: https://github.com/nix-community/nur-combined/blob/main/repos/aster-void/packages/swift-toolchain-bin/package.nix

{ pkgs }:

let
  version = "6.2.3";

  # Swift 6.2.3 - latest stable release with macOS 15 Containerization framework support
  # URL pattern: https://download.swift.org/swift-VERSION-release/xcode/swift-VERSION-RELEASE/swift-VERSION-RELEASE-osx.pkg
  src = pkgs.fetchurl {
    url = "https://download.swift.org/swift-${version}-release/xcode/swift-${version}-RELEASE/swift-${version}-RELEASE-osx.pkg";
    hash = "sha256-we2Ez1QyhsVJyqzMR+C0fYxhw8j+284SBd7cvr52Aag=";
  };

in
pkgs.stdenv.mkDerivation {
  pname = "swift-toolchain-bin";
  inherit version;

  inherit src;
  dontUnpack = true;

  nativeBuildInputs = with pkgs; [
    xar
    cpio
    gzip
  ];

  # Disable fixup phases that don't apply to pre-built binaries
  dontPatchShebangs = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out extract

    # Extract the .pkg (XAR archive)
    cd extract
    xar -xf $src

    # Find and extract the Payload from the main package
    for payload in $(find . -name 'Payload' -type f); do
      echo "Extracting: $payload"
      # Payload is a gzip-compressed cpio archive
      gunzip -c "$payload" | cpio -idm 2>/dev/null || true
    done

    # The Swift toolchain from swift.org has binaries directly in usr/bin
    if [ ! -d "./usr/bin" ]; then
      echo "Error: Could not find usr/bin in extracted package"
      find . -type d | head -50
      exit 1
    fi

    echo "Found Swift toolchain at: ./usr"

    # Copy the toolchain contents to output
    cp -r ./usr $out/
    cp -r ./Developer $out/ 2>/dev/null || true

    # Create convenience symlinks at top-level bin/
    mkdir -p $out/bin
    for tool in swift swiftc swift-build swift-package swift-run swift-test sourcekit-lsp; do
      if [ -f "$out/usr/bin/$tool" ]; then
        ln -sf ../usr/bin/$tool $out/bin/$tool
      fi
    done

    cd ..
    rm -rf extract

    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Swift ${version} toolchain for macOS";
    homepage = "https://swift.org";
    license = licenses.asl20;
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];
  };
}
