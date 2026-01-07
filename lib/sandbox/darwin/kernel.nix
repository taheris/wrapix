# Linux kernel for Apple Containerization framework on arm64
#
# On Darwin, we cannot build the kernel directly - it must be built on Linux
# and provided via remote builder or prebuilt binary.
#
# Requirements:
# - macOS 26+ for Containerization framework
# - Kernel 6.12+ for full VIRTIO_FS support
# - arm64 architecture targeting Apple Silicon

{ pkgs }:

let
  isDarwin = pkgs.stdenv.isDarwin;
  isLinux = !isDarwin;

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

in
if isLinux then
  # On Linux, build the kernel properly
  let
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
    src = kernel;
    dontBuild = true;
    dontConfigure = true;
    installPhase = ''
      mkdir -p $out
      if [ -f arch/arm64/boot/Image ]; then
        cp arch/arm64/boot/Image $out/vmlinux
      elif [ -f vmlinux ]; then
        cp vmlinux $out/vmlinux
      else
        echo "Error: Could not find kernel image"
        exit 1
      fi
    '';
  }
else
  # On Darwin, provide a script that explains how to get the kernel
  pkgs.writeScriptBin "wrapix-kernel-stub" ''
    #!/bin/sh
    echo "The Linux kernel for Apple Containerization must be built on Linux."
    echo ""
    echo "Options:"
    echo "1. Configure a Linux remote builder in /etc/nix/machines"
    echo "2. Build on Linux: nix build .#packages.aarch64-linux.kernel"
    echo "3. Use nixbuild.net or another build service"
    echo ""
    echo "After building, the kernel will be at: result/vmlinux"
    exit 1
  ''
