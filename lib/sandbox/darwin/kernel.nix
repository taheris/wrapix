# Linux kernel for Apple Containerization framework on arm64
#
# On Darwin, we cannot cross-compile the kernel due to toolchain limitations.
# Instead, we provide a stub that will fail at runtime with a helpful message.
# Users need to build the kernel on a Linux machine and provide it separately.
#
# Requirements:
# - Kernel 6.12+ for full VIRTIO_FS support
# - arm64 architecture targeting Apple Silicon
# - Minimal config for fast boot and small footprint

{ pkgs }:

let
  version = "6.12.6";
  majorVersion = "6";

  isDarwin = pkgs.stdenv.isDarwin;

  # Kernel configuration for Apple Containerization
  # Based on arm64 defconfig with VirtIO additions for Containerization framework
  kernelConfig = pkgs.writeText "apple-containerization.config" ''
    # =============================================================================
    # Base Architecture - arm64
    # =============================================================================
    CONFIG_ARM64=y
    CONFIG_64BIT=y
    CONFIG_ARCH_PHYS_ADDR_T_64BIT=y
    CONFIG_ARCH_DMA_ADDR_T_64BIT=y
    CONFIG_MMU=y
    CONFIG_ARM64_VA_BITS_48=y
    CONFIG_ARM64_4K_PAGES=y
    CONFIG_SCHED_MC=y
    CONFIG_NR_CPUS=16
    CONFIG_HOTPLUG_CPU=y

    # =============================================================================
    # Kernel Basics
    # =============================================================================
    CONFIG_SMP=y
    CONFIG_PREEMPT_VOLUNTARY=y
    CONFIG_HZ_250=y
    CONFIG_HZ=250
    CONFIG_NO_HZ_IDLE=y
    CONFIG_HIGH_RES_TIMERS=y
    CONFIG_GENERIC_IRQ_MIGRATION=y
    CONFIG_IRQ_FORCED_THREADING=y

    CONFIG_PRINTK=y
    CONFIG_PRINTK_TIME=y
    CONFIG_BUG=y
    CONFIG_ELF_CORE=y
    CONFIG_FUTEX=y
    CONFIG_EPOLL=y
    CONFIG_SIGNALFD=y
    CONFIG_TIMERFD=y
    CONFIG_EVENTFD=y
    CONFIG_AIO=y
    CONFIG_IO_URING=y
    CONFIG_ADVISE_SYSCALLS=y
    CONFIG_MEMBARRIER=y

    # Kernel module support
    CONFIG_MODULES=y
    CONFIG_MODULE_UNLOAD=y
    CONFIG_MODULE_FORCE_UNLOAD=y
    CONFIG_MODVERSIONS=y

    # =============================================================================
    # Memory Management
    # =============================================================================
    CONFIG_FLATMEM=y
    CONFIG_FLAT_NODE_MEM_MAP=y
    CONFIG_SPARSEMEM_VMEMMAP=y
    CONFIG_COMPACTION=y
    CONFIG_MIGRATION=y
    CONFIG_TRANSPARENT_HUGEPAGE=y
    CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
    CONFIG_SLAB_FREELIST_RANDOM=y
    CONFIG_SLUB=y

    # Memory cgroups for containers
    CONFIG_MEMCG=y
    CONFIG_MEMCG_SWAP=y

    # =============================================================================
    # Virtualization Support (KVM)
    # =============================================================================
    CONFIG_VIRTUALIZATION=y
    CONFIG_KVM=y
    CONFIG_KVM_ARM_HOST=y
    CONFIG_VHOST=y
    CONFIG_VHOST_NET=y
    CONFIG_VHOST_VSOCK=y

    # =============================================================================
    # VirtIO Support (Required for Apple Containerization)
    # =============================================================================
    CONFIG_VIRTIO=y
    CONFIG_VIRTIO_MENU=y
    CONFIG_VIRTIO_PCI=y
    CONFIG_VIRTIO_PCI_LEGACY=y
    CONFIG_VIRTIO_BALLOON=y
    CONFIG_VIRTIO_INPUT=y
    CONFIG_VIRTIO_MMIO=y

    # Block devices
    CONFIG_VIRTIO_BLK=y

    # Network
    CONFIG_VIRTIO_NET=y

    # Console
    CONFIG_VIRTIO_CONSOLE=y
    CONFIG_HVC_DRIVER=y

    # VirtIO filesystem (virtiofs) - critical for shared directories
    CONFIG_VIRTIO_FS=y
    CONFIG_FUSE_FS=y
    CONFIG_DAX_DRIVER=y
    CONFIG_DAX=y
    CONFIG_FS_DAX=y

    # VirtIO vsock for host-guest communication
    CONFIG_VSOCKETS=y
    CONFIG_VIRTIO_VSOCKETS=y
    CONFIG_VIRTIO_VSOCKETS_COMMON=y

    # VirtIO memory balloon
    CONFIG_MEMORY_BALLOON=y

    # =============================================================================
    # Block Devices
    # =============================================================================
    CONFIG_BLOCK=y
    CONFIG_BLK_DEV=y
    CONFIG_BLK_DEV_LOOP=y
    CONFIG_BLK_DEV_RAM=y
    CONFIG_BLK_DEV_RAM_COUNT=16
    CONFIG_BLK_DEV_RAM_SIZE=65536

    # Block cgroups for containers
    CONFIG_BLK_CGROUP=y

    # =============================================================================
    # Networking
    # =============================================================================
    CONFIG_NET=y
    CONFIG_PACKET=y
    CONFIG_UNIX=y
    CONFIG_UNIX_SCM=y
    CONFIG_XFRM=y
    CONFIG_INET=y
    CONFIG_IP_MULTICAST=y
    CONFIG_IP_ADVANCED_ROUTER=y
    CONFIG_IP_MULTIPLE_TABLES=y
    CONFIG_IP_ROUTE_MULTIPATH=y
    CONFIG_NET_IPIP=y
    CONFIG_SYN_COOKIES=y
    CONFIG_IPV6=y
    CONFIG_IPV6_ROUTER_PREF=y
    CONFIG_IPV6_ROUTE_INFO=y
    CONFIG_IPV6_MULTIPLE_TABLES=y
    CONFIG_IPV6_SIT=y

    # Network cgroups for containers
    CONFIG_CGROUP_NET_CLASSID=y
    CONFIG_CGROUP_NET_PRIO=y

    # Netfilter (required for container networking/NAT)
    CONFIG_NETFILTER=y
    CONFIG_NETFILTER_ADVANCED=y
    CONFIG_NF_CONNTRACK=y
    CONFIG_NF_NAT=y
    CONFIG_NF_TABLES=y
    CONFIG_NF_TABLES_IPV4=y
    CONFIG_NF_TABLES_IPV6=y
    CONFIG_NFT_NAT=y
    CONFIG_NFT_MASQ=y
    CONFIG_NFT_REDIR=y
    CONFIG_NFT_CT=y
    CONFIG_NFT_COUNTER=y
    CONFIG_NFT_LOG=y
    CONFIG_NFT_REJECT=y

    # Legacy iptables (for compatibility)
    CONFIG_NETFILTER_XTABLES=y
    CONFIG_IP_NF_IPTABLES=y
    CONFIG_IP_NF_FILTER=y
    CONFIG_IP_NF_TARGET_REJECT=y
    CONFIG_IP_NF_NAT=y
    CONFIG_IP_NF_TARGET_MASQUERADE=y
    CONFIG_IP_NF_TARGET_REDIRECT=y
    CONFIG_IP6_NF_IPTABLES=y
    CONFIG_IP6_NF_FILTER=y
    CONFIG_IP6_NF_NAT=y

    # Network drivers
    CONFIG_NETDEVICES=y
    CONFIG_NET_CORE=y
    CONFIG_TUN=y
    CONFIG_VETH=y
    CONFIG_BRIDGE=y
    CONFIG_MACVLAN=y
    CONFIG_IPVLAN=y
    CONFIG_DUMMY=y

    # =============================================================================
    # Filesystems
    # =============================================================================
    CONFIG_EXT4_FS=y
    CONFIG_EXT4_USE_FOR_EXT2=y
    CONFIG_EXT4_FS_POSIX_ACL=y
    CONFIG_EXT4_FS_SECURITY=y

    CONFIG_XFS_FS=y
    CONFIG_BTRFS_FS=y

    CONFIG_OVERLAY_FS=y
    CONFIG_OVERLAY_FS_REDIRECT_DIR=y
    CONFIG_OVERLAY_FS_INDEX=y

    CONFIG_TMPFS=y
    CONFIG_TMPFS_POSIX_ACL=y
    CONFIG_TMPFS_XATTR=y

    CONFIG_PROC_FS=y
    CONFIG_PROC_SYSCTL=y
    CONFIG_SYSFS=y
    CONFIG_DEVTMPFS=y
    CONFIG_DEVTMPFS_MOUNT=y

    CONFIG_CONFIGFS_FS=y
    CONFIG_AUTOFS_FS=y
    CONFIG_EFIVAR_FS=y

    # 9p filesystem (alternative for shared directories)
    CONFIG_NET_9P=y
    CONFIG_NET_9P_VIRTIO=y
    CONFIG_9P_FS=y
    CONFIG_9P_FS_POSIX_ACL=y
    CONFIG_9P_FS_SECURITY=y

    # Squashfs (for read-only images)
    CONFIG_SQUASHFS=y
    CONFIG_SQUASHFS_ZLIB=y
    CONFIG_SQUASHFS_LZ4=y
    CONFIG_SQUASHFS_ZSTD=y
    CONFIG_SQUASHFS_XZ=y

    # =============================================================================
    # TTY/Console
    # =============================================================================
    CONFIG_TTY=y
    CONFIG_VT=y
    CONFIG_CONSOLE_TRANSLATIONS=y
    CONFIG_VT_CONSOLE=y
    CONFIG_HW_CONSOLE=y
    CONFIG_UNIX98_PTYS=y

    CONFIG_SERIAL_8250=y
    CONFIG_SERIAL_8250_CONSOLE=y
    CONFIG_SERIAL_AMBA_PL011=y
    CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
    CONFIG_SERIAL_EARLYCON=y

    # =============================================================================
    # Container Support (Namespaces, cgroups, seccomp)
    # =============================================================================
    CONFIG_NAMESPACES=y
    CONFIG_UTS_NS=y
    CONFIG_IPC_NS=y
    CONFIG_USER_NS=y
    CONFIG_PID_NS=y
    CONFIG_NET_NS=y
    CONFIG_TIME_NS=y

    CONFIG_CGROUPS=y
    CONFIG_CGROUP_SCHED=y
    CONFIG_CGROUP_PIDS=y
    CONFIG_CGROUP_RDMA=y
    CONFIG_CGROUP_FREEZER=y
    CONFIG_CGROUP_HUGETLB=y
    CONFIG_CGROUP_DEVICE=y
    CONFIG_CGROUP_CPUACCT=y
    CONFIG_CGROUP_PERF=y
    CONFIG_CGROUP_BPF=y
    CONFIG_CPUSETS=y

    CONFIG_CHECKPOINT_RESTORE=y
    CONFIG_SECCOMP=y
    CONFIG_SECCOMP_FILTER=y

    # =============================================================================
    # Security
    # =============================================================================
    CONFIG_KEYS=y
    CONFIG_SECURITY=y
    CONFIG_SECURITY_NETWORK=y
    CONFIG_SECURITYFS=y
    CONFIG_SECURITY_PATH=y

    # Capabilities
    CONFIG_SECURITY_SELINUX=n
    CONFIG_SECURITY_APPARMOR=n
    CONFIG_DEFAULT_SECURITY_DAC=y

    # =============================================================================
    # Cryptography (for encrypted filesystems, TLS, etc.)
    # =============================================================================
    CONFIG_CRYPTO=y
    CONFIG_CRYPTO_ALGAPI=y
    CONFIG_CRYPTO_AEAD=y
    CONFIG_CRYPTO_BLKCIPHER=y
    CONFIG_CRYPTO_HASH=y
    CONFIG_CRYPTO_RNG=y
    CONFIG_CRYPTO_SHA256=y
    CONFIG_CRYPTO_SHA512=y
    CONFIG_CRYPTO_AES=y
    CONFIG_CRYPTO_CBC=y
    CONFIG_CRYPTO_XTS=y
    CONFIG_CRYPTO_GCM=y
    CONFIG_CRYPTO_CHACHA20POLY1305=y
    CONFIG_CRYPTO_DEFLATE=y
    CONFIG_CRYPTO_LZ4=y
    CONFIG_CRYPTO_ZSTD=y
    CONFIG_CRYPTO_USER=y

    # Hardware crypto acceleration on arm64
    CONFIG_CRYPTO_AES_ARM64_CE=y
    CONFIG_CRYPTO_SHA256_ARM64_CE=y
    CONFIG_CRYPTO_SHA512_ARM64_CE=y
    CONFIG_CRYPTO_GHASH_ARM64_CE=y
    CONFIG_CRYPTO_CHACHA20_NEON=y

    # =============================================================================
    # Device Drivers
    # =============================================================================
    CONFIG_PCI=y
    CONFIG_PCIEPORTBUS=y
    CONFIG_PCIE_ECRC=y

    CONFIG_SCSI=y
    CONFIG_BLK_DEV_SD=y
    CONFIG_SCSI_VIRTIO=y

    CONFIG_ATA=y

    # Input
    CONFIG_INPUT=y
    CONFIG_INPUT_EVDEV=y
    CONFIG_INPUT_KEYBOARD=y

    # Framebuffer (for console)
    CONFIG_FB=y
    CONFIG_FB_SIMPLE=y
    CONFIG_FB_EFI=y
    CONFIG_DRM=y
    CONFIG_DRM_FBDEV_EMULATION=y
    CONFIG_DRM_SIMPLEDRM=y
    CONFIG_DRM_VIRTIO_GPU=y

    # RTC
    CONFIG_RTC_CLASS=y
    CONFIG_RTC_DRV_PL031=y

    # =============================================================================
    # Kernel Features for Debugging (minimal)
    # =============================================================================
    CONFIG_PANIC_ON_OOPS=y
    CONFIG_PANIC_TIMEOUT=5
    CONFIG_MAGIC_SYSRQ=y
    CONFIG_DEBUG_INFO=n
    CONFIG_DEBUG_KERNEL=n

    # Disable debug features for smaller kernel
    CONFIG_SLUB_DEBUG=n
    CONFIG_DEBUG_BUGVERBOSE=n
    CONFIG_SCHED_DEBUG=n

    # =============================================================================
    # Boot Configuration
    # =============================================================================
    CONFIG_CMDLINE="console=hvc0 root=/dev/vda rw init=/sbin/init"
    CONFIG_CMDLINE_FORCE=n
    CONFIG_EFI=y
    CONFIG_EFI_STUB=y
  '';

  # Kernel source (extracted to avoid circular dependency with configfile)
  kernelSrc = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v${majorVersion}.x/linux-${version}.tar.xz";
    hash = "sha256-1FCrIV3k4fi7heD0IWdg+jP9AktFJrFE9M4NkBKynJ4=";
  };

in
if isDarwin then
  # On Darwin, cross-compiling the Linux kernel is not supported due to
  # toolchain limitations (elfutils, binutils, etc. are Linux-only).
  # Provide a stub that gives a helpful error at runtime.
  pkgs.runCommand "wrapix-darwin-kernel-stub" {} ''
    mkdir -p $out
    cat > $out/vmlinux << 'EOF'
#!/bin/sh
echo "ERROR: Darwin kernel support requires a pre-built kernel."
echo ""
echo "Cross-compiling the Linux kernel on macOS is not currently supported."
echo "To use wrapix on Darwin, you have two options:"
echo ""
echo "1. Build the kernel on a Linux machine and copy it to ~/.wrapix/vmlinux"
echo "2. Use a remote Nix builder with Linux support"
echo ""
echo "See: https://github.com/taheris/wrapix/docs/darwin-setup.md"
exit 1
EOF
    chmod +x $out/vmlinux
  ''
else
  # On Linux, build the kernel normally
  let
    # Generate kernel config using host tools
    configfile = pkgs.runCommand "kernel-config" {
      nativeBuildInputs = [ pkgs.stdenv.cc pkgs.flex pkgs.bison pkgs.perl pkgs.gnumake ];
    } ''
      tar -xf ${kernelSrc} --strip-components=1 -C .
      cp ${kernelConfig} .config

      # Generate full config using olddefconfig
      make ARCH=arm64 olddefconfig

      cp .config $out
    '';

    # Build the kernel
    kernel = pkgs.linuxManualConfig {
      inherit version configfile;
      src = kernelSrc;
      extraMeta.platforms = [ "aarch64-linux" "x86_64-linux" ];
      allowImportFromDerivation = true;
    };
  in
  # Export the kernel Image file
  pkgs.stdenv.mkDerivation {
    pname = "wrapix-darwin-kernel";
    version = version;

    src = kernel;
    dontBuild = true;
    dontConfigure = true;

    installPhase = ''
      mkdir -p $out
      # The kernel Image is what Apple Containerization expects
      if [ -f arch/arm64/boot/Image ]; then
        cp arch/arm64/boot/Image $out/vmlinux
      elif [ -f vmlinux ]; then
        cp vmlinux $out/vmlinux
      else
        echo "Error: Could not find kernel image"
        exit 1
      fi
    '';

    meta = with pkgs.lib; {
      description = "Linux kernel for Apple Containerization framework";
      license = licenses.gpl2;
      platforms = [ "aarch64-linux" "x86_64-linux" ];
    };
  }
