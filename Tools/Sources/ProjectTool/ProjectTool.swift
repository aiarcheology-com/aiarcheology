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

// --- Subcommand for Git Setup ---

struct GitSetup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Performs required post-clone Git configurations."
    )

    func run() throws {
        // 1. Set --assume-unchanged for CoreData model file
        let filePath = "./ios/MLBrowser/iOS/Persistence/MLBrowser.xcdatamodeld/MLBrowser.xcdatamodel/contents"
        let assumeUnchangedArgs = ["update-index", "--assume-unchanged", filePath]

        let status1 = try runShellCommand("git", arguments: assumeUnchangedArgs)

        if status1 == 0 {
            print("✅ Git --assume-unchanged set for:\n   \(filePath)")
        } else {
            print("❌ Failed to set --assume-unchanged (Exit Code: \(status1))")
            throw ExitCode(status1)
        }

        // 2. Configure git to use .githooks directory for hooks
        let hooksPathArgs = ["config", "core.hooksPath", ".githooks"]

        let status2 = try runShellCommand("git", arguments: hooksPathArgs)

        if status2 == 0 {
            print("✅ Git hooks path set to: .githooks/")
        } else {
            print("❌ Failed to set hooks path (Exit Code: \(status2))")
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