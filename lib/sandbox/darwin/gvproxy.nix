# gvisor-tap-vsock - userspace network stack for VMs
# Provides full TCP/UDP connectivity via vsock without Apple Developer certificate
{ pkgs }:

pkgs.buildGoModule rec {
  pname = "gvisor-tap-vsock";
  version = "0.8.5";

  src = pkgs.fetchFromGitHub {
    owner = "containers";
    repo = "gvisor-tap-vsock";
    rev = "v${version}";
    hash = "sha256-rWZYwQ/wWYAbM0RRNcNboWzKUuNNPDigIFFbFdXDNuo=";
  };

  vendorHash = null;  # vendor folder included in source

  # Build only gvproxy (the host-side daemon)
  subPackages = [ "cmd/gvproxy" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/containers/gvisor-tap-vsock/pkg/types.gitVersion=v${version}"
  ];

  meta = with pkgs.lib; {
    description = "A replacement for libslirp and VPNKit, using gVisor's network stack";
    homepage = "https://github.com/containers/gvisor-tap-vsock";
    license = licenses.asl20;
    platforms = platforms.darwin ++ platforms.linux;
  };
}
