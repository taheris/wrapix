import ArgumentParser
import Containerization
import ContainerizationExtras
import ContainerizationOS
import Foundation

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

            // Process directory mounts from command line
            for mountSpec in dirMount {
                let parts = mountSpec.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }

                let sourcePath = parts[0]
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }

                config.mounts.append(
                    Mount.share(source: sourcePath, destination: parts[1])
                )
            }

            // Process file mounts: mount parent directories (deduplicated), track symlink mappings
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

            // Configure NAT networking (avoids vmnet entitlement requirement)
            config.interfaces.append(
                try NATInterface(
                    ipv4Address: CIDRv4("10.0.0.2/24"),
                    ipv4Gateway: IPv4Address("10.0.0.1")
                )
            )

            // Use gateway as DNS server (standard NAT setup)
            config.dns = .init(nameservers: ["10.0.0.1"])

            // Run entrypoint script (creates user, runs claude)
            config.process.arguments = ["/entrypoint.sh"]
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
