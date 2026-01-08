import ArgumentParser
import Containerization
import ContainerizationExtras
import Foundation

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

    @Option(name: .long, parsing: .upToNextOption, help: "Mounts in source:dest format")
    var mount: [String] = []

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

            // Mount project directory
            config.mounts.append(
                Mount.share(
                    source: projectDir,
                    destination: "/workspace"
                )
            )

            // Process mounts from command line (only directories - files not supported)
            for mountSpec in mount {
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
            config.process.environmentVariables = [
                "HOST_UID=\(getuid())",
                "HOST_USER=\(NSUserName())",
                "ANTHROPIC_API_KEY=\(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")",
                "WRAPIX_PROMPT=\(ProcessInfo.processInfo.environment["WRAPIX_PROMPT"] ?? "")"
            ]
        }

        try await container.create()
        try await container.start()

        // Wait for container to exit
        let exitStatus = try await container.wait()
        try await container.stop()

        Darwin.exit(exitStatus.exitCode)
    }
}
