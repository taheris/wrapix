# Build the wrapix-runner Swift CLI for Darwin
#
# This CLI uses Apple's Containerization framework (macOS 26+) to run
# Linux containers in a lightweight VM.
#
# Requirements:
# - macOS 26+ with Containerization framework
# - Swift 6.x toolchain (provided by swift-toolchain.nix)

{ pkgs }:

let
  swiftToolchain = import ./swift-toolchain.nix { inherit pkgs; };
  swiftSource = ./swift;

in pkgs.stdenv.mkDerivation {
  pname = "wrapix-runner";
  version = "0.1.0";

  src = swiftSource;

  nativeBuildInputs = [ swiftToolchain ];

  # Swift needs HOME for package cache
  HOME = "/tmp/swift-build";

  buildPhase = ''
    mkdir -p $HOME

    # Build the Swift package in release mode
    ${swiftToolchain}/bin/swift build -c release \
      --build-path .build \
      -Xswiftc -sdk -Xswiftc /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
      2>&1 || {
        echo "Build failed. Containerization framework requires macOS 26+ and Xcode 26+."
        exit 1
      }
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp .build/release/wrapix-runner $out/bin/
  '';

  meta = with pkgs.lib; {
    description = "Run Claude Code in a sandboxed container on macOS";
    homepage = "https://github.com/taheris/wrapix";
    license = licenses.mit;
    platforms = [ "aarch64-darwin" "x86_64-darwin" ];
    mainProgram = "wrapix-runner";
  };
}
