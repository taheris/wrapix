# Linux kernel for Apple Containerization framework on arm64
#
# This module expects Linux pkgs to be passed in. On Darwin, the parent module
# passes linuxPkgs which will build via a remote Linux builder.
#
# Uses the official Apple Containerization kernel config from:
# https://github.com/apple/containerization/tree/main/kernel

{ pkgs }:

let
  version = "6.14.9";
  majorVersion = "6";

  # Fetch the official Apple Containerization kernel config (pinned to commit)
  containerizationRev = "fc5399e77e5735f59d9eb73b8332af7a3bf0836f";
  kernelConfig = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/apple/containerization/${containerizationRev}/kernel/config-arm64";
    hash = "sha256-CwVAjX1fXV6UHYl2d4Dch6LpDi+O8g7G+M8RowN/nzY=";
  };

  kernelSrc = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v${majorVersion}.x/linux-${version}.tar.xz";
    hash = "sha256-OQzd4DJxmSWghCcnAZfvVdtOkMCdRU6cNVQVcpLJ82E=";
  };

  configfile =
    pkgs.runCommand "kernel-config"
      {
        nativeBuildInputs = [
          pkgs.stdenv.cc
          pkgs.flex
          pkgs.bison
          pkgs.perl
          pkgs.gnumake
        ];
      }
      ''
        tar -xf ${kernelSrc} --strip-components=1 -C .
        cp ${kernelConfig} .config
        make ARCH=arm64 olddefconfig
        cp .config $out
      '';

  kernel = pkgs.linuxManualConfig {
    inherit version configfile;
    src = kernelSrc;
    extraMeta.platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    allowImportFromDerivation = true;
  };
in
pkgs.stdenv.mkDerivation {
  pname = "wrapix-darwin-kernel";
  inherit version;
  dontUnpack = true;
  dontBuild = true;
  dontConfigure = true;
  installPhase = ''
    mkdir -p $out
    cp ${kernel}/Image $out/vmlinux
  '';
}
