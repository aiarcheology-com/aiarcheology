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
        abstract: "Performs project setup: installs tools and configures git."
    )

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

            // 3. Optionally setup direnv for directory aliases
            print("")
            try setupDirenv()
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

        // Install missing/outdated tools
        if hasIssues {
            print("")
            print("🔄 Installing/updating tools...")

            for (name, spec) in missingTools {
                try ToolsManager.installTool(name: name, spec: spec)
            }

            for (name, spec, _) in outdatedTools {
                try ToolsManager.installTool(name: name, spec: spec)
            }

            // Re-check after installation
            print("")
            print("📦 Verifying installations...")
            let newResults = ToolsManager.checkAllTools(config: config)
            for (name, spec, status) in newResults {
                ToolsManager.printToolStatus(name: name, spec: spec, status: status)
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

    private func setupDirenv() throws {
        let envrcPath = "./.envrc"
        let templatePath = "./.envrc.template"

        // Check if .envrc already exists
        if FileManager.default.fileExists(atPath: envrcPath) {
            print("🔗 Directory aliases already configured (.envrc exists)")
            return
        }

        // Check if template exists
        guard FileManager.default.fileExists(atPath: templatePath) else {
            print("⏭️  Skipping directory aliases (.envrc.template not found)")
            return
        }

        // Ask user if they want to use aliases
        print("🔗 Would you like to use short command aliases in this project?")
        print("   Available: aiasetup, aiaswiftlint, aiaswiftgen, aiaharmonize, aiapipeline")
        print("   Enable aliases? [y/N]: ", terminator: "")

        guard let response = readLine()?.lowercased(), response == "y" || response == "yes" else {
            print("   ⏭️  Skipped directory aliases")
            return
        }

        // Check if direnv is installed
        let direnvInstalled = isDirenvInstalled()

        if !direnvInstalled {
            print("   direnv is required but not installed.")
            print("   Install direnv now? [y/N]: ", terminator: "")

            guard let installResponse = readLine()?.lowercased(), installResponse == "y" || installResponse == "yes" else {
                print("   ⏭️  Skipped - direnv not installed")
                return
            }

            // Install direnv via Homebrew
            print("   Installing direnv via Homebrew...")
            let brewStatus = try runShellCommand("brew", arguments: ["install", "direnv"])

            guard brewStatus == 0 else {
                print("   ❌ Failed to install direnv")
                print("   Try manually: brew install direnv")
                return
            }

            print("   ✅ direnv installed")
            print("")
            print("   ⚠️  Add this to your ~/.zshrc to activate direnv:")
            print("      eval \"$(direnv hook zsh)\"")
            print("")
        }

        // Copy template to .envrc
        do {
            try FileManager.default.copyItem(atPath: templatePath, toPath: envrcPath)
            print("   ✅ Created .envrc from template")
        } catch {
            print("   ❌ Failed to create .envrc: \(error.localizedDescription)")
            return
        }

        // Run direnv allow
        print("-> Executing: direnv allow")
        let allowTask = Process()
        allowTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        allowTask.arguments = ["direnv", "allow"]

        try allowTask.run()
        allowTask.waitUntilExit()

        if allowTask.terminationStatus == 0 {
            print("   ✅ Directory aliases enabled")
            print("   Available commands: aiasetup, aiaswiftlint, aiaswiftgen, aiaharmonize, aiapipeline")
            print("")
            print("   To activate now, run:")
            print("      eval \"$(direnv export zsh)\"")
            print("   Or simply: cd . ")
        } else {
            print("   ⚠️  direnv allow failed - run manually: direnv allow")
        }
    }

    private func isDirenvInstalled() -> Bool {
        let whichTask = Process()
        whichTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        whichTask.arguments = ["which", "direnv"]
        whichTask.standardOutput = FileHandle.nullDevice
        whichTask.standardError = FileHandle.nullDevice

        do {
            try whichTask.run()
            whichTask.waitUntilExit()
            return whichTask.terminationStatus == 0
        } catch {
            return false
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