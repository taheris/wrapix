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

    @Option(name: .long, help: "Path to OCI image tarball")
    var imagePath: String

    @Option(name: .long, help: "Path to Linux kernel")
    var kernelPath: String

    @Option(name: .long, help: "Memory in GB (default: 4)")
    var memory: Int = 4

    @Option(name: .long, help: "Number of CPUs (default: half of available)")
    var cpus: Int?

    func run() async throws {
        let kernel = Kernel(path: URL(fileURLWithPath: kernelPath))

        let manager = try await ContainerManager(
            kernel: kernel,
            network: try ContainerManager.VmnetNetwork()
        )

        // Load OCI image
        let imageURL = URL(fileURLWithPath: imagePath)

        // Default to half of available CPUs for efficiency
        let cpuCount = cpus ?? max(2, ProcessInfo.processInfo.processorCount / 2)

        let container = try await manager.create("wrapix") { config in
            config.cpus = cpuCount
            config.memoryInBytes = UInt64(memory) * 1024 * 1024 * 1024

            // Mount project directory
            config.mounts.append(
                Mount.share(
                    source: URL(fileURLWithPath: projectDir),
                    destination: "/workspace"
                )
            )

            // Mount Claude config
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            config.mounts.append(
                Mount.share(
                    source: homeDir.appendingPathComponent(".claude"),
                    destination: "/home/\(NSUserName())/.claude"
                )
            )

            // Run entrypoint
            config.process.arguments = ["/entrypoint.sh"]
            config.process.environmentVariables = [
                "HOST_UID": String(getuid()),
                "HOST_USER": NSUserName(),
                "ANTHROPIC_API_KEY": ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
            ]
        }

        try await container.start()

        // Wait for container to exit
        let exitCode = try await container.wait()
        Darwin.exit(exitCode)
    }
}
