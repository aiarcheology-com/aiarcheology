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
        let filePath = "./ios/AI Archeology/iOS/Persistence/MLBrowser.xcdatamodeld/MLBrowser.xcdatamodel/contents"
        let arguments = ["update-index", "--assume-unchanged", filePath]
        
        let status = try runShellCommand("git", arguments: arguments)

        if status == 0 {
            print("✅ Git **--assume-unchanged** set for:\n   \(filePath)")
        } else {
            print("❌ Failed to set **--assume-unchanged** (Exit Code: \(status))")
            throw ExitCode(status)
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