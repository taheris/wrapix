import ArgumentParser
import Containerization
import ContainerizationExtras
import ContainerizationOS
import Foundation
import Virtualization

/// Writer that forwards data to a FileHandle (stdout/stderr)
final class FileHandleWriter: Writer, @unchecked Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func close() throws {
        // Don't close stdout/stderr
    }
}

/// ReaderStream that reads from a FileHandle (stdin)
final class FileHandleReaderStream: ReaderStream, @unchecked Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func stream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                self.handle.readabilityHandler = nil
            }
        }
    }
}

/// Network interface using gvproxy for user-mode networking via VZFileHandleNetworkDeviceAttachment.
/// This provides full TCP/UDP connectivity unlike VZNATNetworkDeviceAttachment (which only routes ICMP).
struct GvproxyInterface: Interface {
    var ipv4Address: CIDRv4
    var ipv4Gateway: IPv4Address?
    var macAddress: MACAddress?

    /// File handle connected to gvproxy's unixgram socket
    let networkFileHandle: FileHandle

    init(ipv4Address: CIDRv4, ipv4Gateway: IPv4Address?, macAddress: MACAddress? = nil, networkFileHandle: FileHandle) {
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.networkFileHandle = networkFileHandle
    }
}

extension GvproxyInterface: VZInterface {
    func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        if let macAddress = self.macAddress {
            guard let mac = VZMACAddress(string: macAddress.description) else {
                throw NSError(domain: "GvproxyInterface", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "invalid mac address \(macAddress)"])
            }
            config.macAddress = mac
        }
        config.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: networkFileHandle)
        return config
    }
}

/// Manages gvproxy subprocess lifecycle
final class GvproxyManager {
    private let process: Process
    private let socketPath: URL
    private let vmSocketFd: Int32

    /// File handle for the VM side of the socket pair (to be used with VZFileHandleNetworkDeviceAttachment)
    let vmFileHandle: FileHandle

    private init(process: Process, socketPath: URL, vmFileHandle: FileHandle, vmSocketFd: Int32) {
        self.process = process
        self.socketPath = socketPath
        self.vmFileHandle = vmFileHandle
        self.vmSocketFd = vmSocketFd
    }

    /// Start gvproxy and return a manager instance
    static func start(gvproxyPath: String, socketDir: URL) throws -> GvproxyManager {
        let fm = FileManager.default
        try fm.createDirectory(at: socketDir, withIntermediateDirectories: true)

        // Socket paths for gvproxy
        let apiSocketPath = socketDir.appendingPathComponent("gvproxy.sock")
        let vfkitSocketPath = socketDir.appendingPathComponent("vfkit.sock")

        // Remove existing sockets if present
        try? fm.removeItem(at: apiSocketPath)
        try? fm.removeItem(at: vfkitSocketPath)

        // Start gvproxy process with vfkit-style unixgram socket
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gvproxyPath)
        process.arguments = [
            "-listen", "unix://\(apiSocketPath.path)",
            "-listen-vfkit", "unixgram://\(vfkitSocketPath.path)",
            "-ssh-port", "-1"  // Disable SSH forwarding
        ]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        // Wait for gvproxy to create its socket (with retry)
        var socketReady = false
        for _ in 0..<50 {  // Up to 5 seconds
            usleep(100_000)  // 100ms
            if fm.fileExists(atPath: vfkitSocketPath.path) {
                socketReady = true
                break
            }
        }

        guard socketReady else {
            process.terminate()
            throw NSError(domain: "GvproxyManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "gvproxy failed to create socket at \(vfkitSocketPath.path)"])
        }

        // Connect to gvproxy's vfkit socket (datagram socket like vfkit)
        let sock = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            process.terminate()
            throw NSError(domain: "GvproxyManager", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "socket() failed: \(String(cString: strerror(errno)))"])
        }

        // Bind our socket to a local path (required for datagram sockets so server can reply)
        let clientSocketPath = socketDir.appendingPathComponent("vm.sock")
        try? fm.removeItem(at: clientSocketPath)

        var clientAddr = sockaddr_un()
        clientAddr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &clientAddr.sun_path) { ptr in
            clientSocketPath.path.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &clientAddr, { ptr in
            bind(sock, UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self), addrLen)
        }) == 0 else {
            close(sock)
            process.terminate()
            throw NSError(domain: "GvproxyManager", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "bind() failed: \(String(cString: strerror(errno)))"])
        }

        // Connect to gvproxy's socket
        var serverAddr = sockaddr_un()
        serverAddr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &serverAddr.sun_path) { ptr in
            vfkitSocketPath.path.withCString { cstr in
                _ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
            }
        }

        guard withUnsafePointer(to: &serverAddr, { ptr in
            connect(sock, UnsafeRawPointer(ptr).assumingMemoryBound(to: sockaddr.self), addrLen)
        }) == 0 else {
            close(sock)
            process.terminate()
            throw NSError(domain: "GvproxyManager", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "connect() to gvproxy failed: \(String(cString: strerror(errno)))"])
        }

        // Send vfkit magic handshake "VFKT" (4 ASCII bytes)
        // This tells gvproxy we're ready to send/receive Ethernet frames
        let magic = Data("VFKT".utf8)
        let sent = magic.withUnsafeBytes { ptr in
            Darwin.write(sock, ptr.baseAddress, 4)
        }
        guard sent == 4 else {
            close(sock)
            process.terminate()
            throw NSError(domain: "GvproxyManager", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to send vfkit magic handshake"])
        }

        let vmFileHandle = FileHandle(fileDescriptor: sock, closeOnDealloc: true)

        return GvproxyManager(
            process: process,
            socketPath: socketDir,
            vmFileHandle: vmFileHandle,
            vmSocketFd: sock
        )
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()

        // Clean up socket files
        try? FileManager.default.removeItem(at: socketPath)
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }
}

@main
struct SandboxRunner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wrapix-runner",
        abstract: "Run Claude Code in a sandboxed VM"
    )

    @Argument(help: "Project directory to mount at /workspace")
    var projectDir: String

    @Option(name: .long, help: "Container image reference (e.g., docker.io/library/ubuntu:latest)")
    var image: String

    @Option(name: .long, help: "Path to Linux kernel")
    var kernelPath: String

    @Option(name: .long, help: "Initfs image reference")
    var initfs: String = "vminit:latest"

    @Option(name: .long, help: "Memory in MB (default: 4096)")
    var memory: Int = 4096

    @Option(name: .long, help: "Number of CPUs (default: half of available)")
    var cpus: Int?

    @Option(name: .long, parsing: .upToNextOption, help: "Directory mounts in source:dest format")
    var dirMount: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "File mounts in source:dest format (mounted via parent directory)")
    var fileMount: [String] = []

    @Option(name: .long, help: "Path to gvproxy binary for user-mode networking (provides full TCP/UDP)")
    var gvproxyPath: String?

    @Option(name: .long, parsing: .remaining, help: "Custom command to run instead of /entrypoint.sh (for testing)")
    var command: [String] = []

    func run() async throws {
        let kernel = Kernel(
            path: URL(fileURLWithPath: kernelPath),
            platform: .linuxArm
        )

        var manager = try await ContainerManager(
            kernel: kernel,
            initfsReference: initfs
        )

        // Use unique container name based on PID to allow multiple instances
        let containerName = "wrapix-\(ProcessInfo.processInfo.processIdentifier)"

        // Default to half of available CPUs for efficiency
        let cpuCount = cpus ?? max(2, ProcessInfo.processInfo.processorCount / 2)

        // Start gvproxy for user-mode networking (provides full TCP/UDP connectivity)
        var gvproxyManager: GvproxyManager? = nil
        if let gvproxyPath = gvproxyPath {
            let socketDir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("wrapix-\(ProcessInfo.processInfo.processIdentifier)")
            gvproxyManager = try GvproxyManager.start(gvproxyPath: gvproxyPath, socketDir: socketDir)
        }

        defer {
            gvproxyManager?.stop()
        }

        // Check if we have a TTY for interactive mode
        let hasTTY = isatty(STDIN_FILENO) != 0
        let terminal: Terminal?
        let sigwinchStream: AsyncSignalHandler?

        if hasTTY {
            // Set up terminal for interactive I/O
            terminal = try Terminal.current
            try terminal!.setraw()
            sigwinchStream = AsyncSignalHandler.create(notify: [SIGWINCH])
        } else {
            terminal = nil
            sigwinchStream = nil
        }

        defer {
            terminal?.tryReset()
        }

        // Ensure cleanup on exit
        defer {
            try? manager.delete(containerName)
        }

        let container = try await manager.create(
            containerName,
            reference: image,
            rootfsSizeInBytes: 4 * 1024 * 1024 * 1024  // 4GB rootfs
        ) { config in
            config.cpus = cpuCount
            config.memoryInBytes = UInt64(memory) * 1024 * 1024

            // Set up I/O based on whether we have a TTY
            if let terminal = terminal {
                config.process.setTerminalIO(terminal: terminal)
            } else {
                // Pipe mode: forward stdin/stdout/stderr
                config.process.stdin = FileHandleReaderStream(FileHandle.standardInput)
                config.process.stdout = FileHandleWriter(FileHandle.standardOutput)
                config.process.stderr = FileHandleWriter(FileHandle.standardError)
            }

            // Mount project directory
            config.mounts.append(
                Mount.share(
                    source: projectDir,
                    destination: "/workspace"
                )
            )

            // Process directory mounts: mount to staging location, entrypoint copies with correct ownership
            // (VirtioFS maps all files as root, so we can't mount directly to destination)
            var dirMountMappings: [String] = []
            var dirMountIndex = 0
            for mountSpec in dirMount {
                let parts = mountSpec.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }

                let sourcePath = parts[0]
                let destPath = parts[1]
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }

                let mountPoint = "/mnt/wrapix/dir-mount/\(dirMountIndex)"
                dirMountIndex += 1

                config.mounts.append(
                    Mount.share(source: sourcePath, destination: mountPoint)
                )
                dirMountMappings.append("\(mountPoint):\(destPath)")
            }

            // Pass directory mount mappings to entrypoint for copy with correct ownership
            let dirMountsEnv = dirMountMappings.joined(separator: ",")
            if !dirMountsEnv.isEmpty {
                config.process.environmentVariables.append("WRAPIX_DIR_MOUNTS=\(dirMountsEnv)")
            }

            // Process file mounts: mount parent directories (deduplicated), track mappings
            // Group files by parent directory to avoid duplicate mounts
            var parentDirToMountPoint: [String: String] = [:]
            var fileMountMappings: [String] = []
            var mountIndex = 0

            for mountSpec in fileMount {
                let parts = mountSpec.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }

                let sourcePath = parts[0]
                let destPath = parts[1]

                // Verify source file exists
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }

                let sourceURL = URL(fileURLWithPath: sourcePath)
                let parentDir = sourceURL.deletingLastPathComponent().path
                let filename = sourceURL.lastPathComponent

                // Get or create mount point for this parent directory
                let mountPoint: String
                if let existing = parentDirToMountPoint[parentDir] {
                    mountPoint = existing
                } else {
                    mountPoint = "/mnt/wrapix/file-mount/\(mountIndex)"
                    parentDirToMountPoint[parentDir] = mountPoint
                    mountIndex += 1

                    // Mount parent directory to unique mount point
                    config.mounts.append(
                        Mount.share(source: parentDir, destination: mountPoint)
                    )
                }

                // Track mapping: source_in_mount:destination
                fileMountMappings.append("\(mountPoint)/\(filename):\(destPath)")
            }

            // Pass file mount mappings to entrypoint for symlink creation
            let fileMountsEnv = fileMountMappings.joined(separator: ",")
            if !fileMountsEnv.isEmpty {
                config.process.environmentVariables.append("WRAPIX_FILE_MOUNTS=\(fileMountsEnv)")
            }

            // Configure networking
            if let gvproxyManager = gvproxyManager {
                // Use gvproxy for full TCP/UDP connectivity
                // gvproxy defaults: gateway 192.168.127.1, VM IP assigned via DHCP
                config.interfaces.append(
                    GvproxyInterface(
                        ipv4Address: try CIDRv4("192.168.127.2/24"),
                        ipv4Gateway: try IPv4Address("192.168.127.1"),
                        networkFileHandle: gvproxyManager.vmFileHandle
                    )
                )
                // gvproxy provides DNS at the gateway address
                config.dns = .init(nameservers: ["192.168.127.1"])
            } else {
                // Fallback to NAT networking (WARNING: only routes ICMP, not TCP/UDP)
                config.interfaces.append(
                    try NATInterface(
                        ipv4Address: CIDRv4("192.168.64.2/24"),
                        ipv4Gateway: IPv4Address("192.168.64.1")
                    )
                )
                // Use public DNS (gateway doesn't provide DNS forwarding)
                config.dns = .init(nameservers: ["1.1.1.1"])
            }

            // Run custom command if provided, otherwise run entrypoint
            if command.isEmpty {
                config.process.arguments = ["/entrypoint.sh"]
            } else {
                config.process.arguments = command
            }
            config.process.environmentVariables.append(contentsOf: [
                "HOST_UID=\(getuid())",
                "HOST_USER=\(NSUserName())",
                "ANTHROPIC_API_KEY=\(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")",
                "WRAPIX_PROMPT=\(ProcessInfo.processInfo.environment["WRAPIX_PROMPT"] ?? "")",
                "WRAPIX_DARWIN_VM=1"  // Signal to entrypoint that we're in Darwin VM mode
            ])
        }

        try await container.create()
        try await container.start()

        // Resize to current terminal size if we have a TTY
        if let terminal = terminal {
            try? await container.resize(to: try terminal.size)
        }

        // Handle resize events and wait for container exit
        if let sigwinchStream = sigwinchStream, let terminal = terminal {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in sigwinchStream.signals {
                        try await container.resize(to: try terminal.size)
                    }
                }

                let exitStatus = try await container.wait()
                group.cancelAll()

                try await container.stop()
                Darwin.exit(exitStatus.exitCode)
            }
        } else {
            // No TTY - just wait for container to exit
            let exitStatus = try await container.wait()
            try await container.stop()
            Darwin.exit(exitStatus.exitCode)
        }
    }
}
