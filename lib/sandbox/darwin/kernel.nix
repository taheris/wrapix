# Linux kernel for Apple Containerization framework on arm64
#
# This module expects Linux pkgs to be passed in. On Darwin, the parent module
# passes linuxPkgs which will build via a remote Linux builder.
#
# Requirements:
# - Kernel 6.12+ for full VIRTIO_FS support
# - arm64 architecture targeting Apple Silicon

{ pkgs }:

let
  version = "6.12.6";
  majorVersion = "6";

  # Kernel configuration for Apple Containerization (VirtIO-based)
  kernelConfigText = ''
    CONFIG_ARM64=y
    CONFIG_64BIT=y
    CONFIG_SMP=y
    CONFIG_VIRTIO=y
    CONFIG_VIRTIO_PCI=y
    CONFIG_VIRTIO_BLK=y
    CONFIG_VIRTIO_NET=y
    CONFIG_VIRTIO_CONSOLE=y
    CONFIG_VIRTIO_FS=y
    CONFIG_FUSE_FS=y
    CONFIG_NAMESPACES=y
    CONFIG_CGROUPS=y
    CONFIG_SECCOMP=y
    CONFIG_NET=y
    CONFIG_INET=y
    CONFIG_EXT4_FS=y
    CONFIG_OVERLAY_FS=y
    CONFIG_TMPFS=y
  '';

  kernelConfig = pkgs.writeText "apple-containerization.config" kernelConfigText;

  kernelSrc = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v${majorVersion}.x/linux-${version}.tar.xz";
    hash = "sha256-1FCrIV3k4fi7heD0IWdg+jP9AktFJrFE9M4NkBKynJ4=";
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
    if [ -f ${kernel}/Image ]; then
      cp ${kernel}/Image $out/vmlinux
    elif [ -f ${kernel}/vmlinuz ]; then
      cp ${kernel}/vmlinuz $out/vmlinux
    elif [ -f ${kernel}/bzImage ]; then
      cp ${kernel}/bzImage $out/vmlinux
    else
      echo "Error: Could not find kernel image in ${kernel}"
      ls -la ${kernel}/ || true
      exit 1
    fi
  '';
}
