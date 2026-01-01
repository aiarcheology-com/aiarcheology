import Foundation
import ArgumentParser

// --- Helper Function to run shell commands ---

@discardableResult
func runShellCommand(_ command: String, arguments: [String]) throws -> Int32 {
    let task = Process()
    // Using /usr/bin/env to ensure 'git' is found via the PATH
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = [command] + arguments
    
    let commandString = ([command] + arguments).joined(separator: " ")
    print("-> Executing: \(commandString)")

    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    } catch {
        print("❌ Fatal Error executing command: \(error)")
        throw ExitCode.failure
    }
}


// --- Main Tool Definition ---

@main
struct ProjectTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A Swift-based CLI for project setup and maintenance tasks.",
        subcommands: [GitSetup.self, Cleanup.self, Secrets.self]
    )
}

// --- Subcommand for Setup ---

struct GitSetup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Performs project setup: validates/installs tools and configures git."
    )

    @Flag(name: .long, help: "Install missing tools via Homebrew")
    var install: Bool = false

    /// Check if running in CI environment
    static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil ||
        ProcessInfo.processInfo.environment["CI_XCODE_CLOUD"] != nil
    }

    func run() throws {
        print("🔧 Project Setup")
        print("")

        // 1. Check/install required tools
        try setupTools()

        // 2. Configure git (skip in CI - not needed for fresh clones)
        if GitSetup.isCI {
            print("")
            print("⏭️  Skipping git configuration in CI environment")
        } else {
            print("")
            try setupGit()
        }

        print("")
        print("✅ Setup complete")
    }

    private func setupTools() throws {
        print("📦 Checking required tools...")

        let config = try ToolsManager.loadConfiguration()
        let results = ToolsManager.checkAllTools(config: config)

        var hasIssues = false
        var missingTools: [(name: String, spec: ToolsConfiguration.ToolSpec)] = []
        var outdatedTools: [(name: String, spec: ToolsConfiguration.ToolSpec, currentVersion: String)] = []

        for (name, spec, status) in results {
            ToolsManager.printToolStatus(name: name, spec: spec, status: status)

            switch status {
            case .notInstalled:
                hasIssues = true
                missingTools.append((name: name, spec: spec))
            case .installed(let version, let matches):
                if !matches {
                    hasIssues = true
                    outdatedTools.append((name: name, spec: spec, currentVersion: version))
                }
            case .versionCheckFailed:
                hasIssues = true
            }
        }

        // Handle missing/outdated tools
        if hasIssues {
            if install {
                print("")
                print("🔄 Installing/updating tools...")

                for (name, spec) in missingTools {
                    try ToolsManager.installTool(name: name, spec: spec)
                }

                for (name, spec, _) in outdatedTools {
                    try ToolsManager.upgradeTool(name: name, spec: spec)
                }

                // Re-check after installation
                print("")
                print("📦 Verifying installations...")
                let newResults = ToolsManager.checkAllTools(config: config)
                for (name, spec, status) in newResults {
                    ToolsManager.printToolStatus(name: name, spec: spec, status: status)
                }
            } else {
                print("")
                print("💡 Run with --install to automatically install missing tools:")
                print("   swift run --package-path Tools ProjectTool setup --install")
            }
        }
    }

    private func setupGit() throws {
        print("🔗 Configuring git...")

        // 1. Set --assume-unchanged for CoreData model file
        let filePath = "./ios/MLBrowser/iOS/Persistence/MLBrowser.xcdatamodeld/MLBrowser.xcdatamodel/contents"
        let assumeUnchangedArgs = ["update-index", "--assume-unchanged", filePath]

        let status1 = try runShellCommand("git", arguments: assumeUnchangedArgs)

        if status1 == 0 {
            print("   ✅ Git --assume-unchanged set for CoreData model")
        } else {
            print("   ❌ Failed to set --assume-unchanged (Exit Code: \(status1))")
            throw ExitCode(status1)
        }

        // 2. Configure git to use .githooks directory for hooks
        let hooksPathArgs = ["config", "core.hooksPath", ".githooks"]

        let status2 = try runShellCommand("git", arguments: hooksPathArgs)

        if status2 == 0 {
            print("   ✅ Git hooks path set to: .githooks/")
        } else {
            print("   ❌ Failed to set hooks path (Exit Code: \(status2))")
            throw ExitCode(status2)
        }
    }
}

// --- Optional Cleanup Subcommand (Example) ---

struct Cleanup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "Cleans project build artifacts and Swift caches."
    )

    func run() throws {
        print("🧹 Cleaning up SwiftPM build artifacts...")
        // Example of running another command
        try runShellCommand("rm", arguments: ["-rf", ".build"])
        print("✅ Cleanup complete.")
    }
}