import ArgumentParser
import Containerization
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
    var initfs: String = "ghcr.io/apple/containerization/initfs:latest"

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
            initfsReference: initfs,
            network: try ContainerManager.VmnetNetwork()
        )

        // Default to half of available CPUs for efficiency
        let cpuCount = cpus ?? max(2, ProcessInfo.processInfo.processorCount / 2)

        let container = try await manager.create("wrapix", reference: image) { config in
            config.cpus = cpuCount
            config.memoryInBytes = UInt64(memory) * 1024 * 1024

            // Mount project directory
            config.mounts.append(
                Mount.share(
                    source: projectDir,
                    destination: "/workspace"
                )
            )

            // Process mounts from command line
            for mountSpec in mount {
                let parts = mountSpec.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }

                let sourcePath = parts[0]
                guard FileManager.default.fileExists(atPath: sourcePath) else { continue }

                config.mounts.append(
                    Mount.share(source: sourcePath, destination: parts[1])
                )
            }

            // Run entrypoint
            config.process.arguments = ["/entrypoint.sh"]
            config.process.environmentVariables = [
                "HOST_UID=\(getuid())",
                "HOST_USER=\(NSUserName())",
                "ANTHROPIC_API_KEY=\(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")"
            ]
        }

        try await container.start()

        // Wait for container to exit
        let exitStatus = try await container.wait()
        try await container.stop()

        Darwin.exit(exitStatus.exitCode)
    }
}
