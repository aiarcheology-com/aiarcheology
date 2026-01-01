//
//  ToolsConfiguration.swift
//  ProjectTool
//
//  Manages required tool versions from .tools.json configuration.
//

import ArgumentParser
import Foundation

// MARK: - Tools Configuration Model

struct ToolsConfiguration: Codable {
    let tools: [String: ToolSpec]

    struct ToolSpec: Codable {
        let version: String
        let brew: String
        let versionCommand: String
        let versionPattern: String
    }
}

// MARK: - Tool Status

enum ToolStatus {
    case installed(version: String, matches: Bool)
    case notInstalled
    case versionCheckFailed(error: String)
}

// MARK: - Tools Manager

struct ToolsManager {

    static let configPath = "./.tools.json"

    /// Load tools configuration from .tools.json
    static func loadConfiguration() throws -> ToolsConfiguration {
        let url = URL(fileURLWithPath: configPath)

        guard FileManager.default.fileExists(atPath: configPath) else {
            print("❌ Configuration file not found: \(configPath)")
            throw ExitCode.failure
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(ToolsConfiguration.self, from: data)
    }

    /// Check if a tool is installed and get its version
    static func checkTool(name: String, spec: ToolsConfiguration.ToolSpec) -> ToolStatus {
        // Check if command exists
        let whichTask = Process()
        whichTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        whichTask.arguments = ["which", name]
        whichTask.standardOutput = FileHandle.nullDevice
        whichTask.standardError = FileHandle.nullDevice

        do {
            try whichTask.run()
            whichTask.waitUntilExit()

            if whichTask.terminationStatus != 0 {
                return .notInstalled
            }
        } catch {
            return .notInstalled
        }

        // Get version
        let versionTask = Process()
        versionTask.executableURL = URL(fileURLWithPath: "/bin/bash")
        versionTask.arguments = ["-c", spec.versionCommand]

        let pipe = Pipe()
        versionTask.standardOutput = pipe
        versionTask.standardError = FileHandle.nullDevice

        do {
            try versionTask.run()
            versionTask.waitUntilExit()

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return .versionCheckFailed(error: "Could not read version output")
            }

            // Extract version using regex pattern
            guard let regex = try? NSRegularExpression(pattern: spec.versionPattern, options: []),
                  let match = regex.firstMatch(in: output, options: [], range: NSRange(output.startIndex..., in: output)),
                  let range = Range(match.range(at: 1), in: output) else {
                // Try matching group 0 if group 1 doesn't exist
                if let regex = try? NSRegularExpression(pattern: spec.versionPattern, options: []),
                   let match = regex.firstMatch(in: output, options: [], range: NSRange(output.startIndex..., in: output)),
                   let range = Range(match.range(at: 0), in: output) {
                    let version = String(output[range])
                    return .installed(version: version, matches: version == spec.version)
                }
                return .versionCheckFailed(error: "Version pattern did not match output: \(output)")
            }

            let version = String(output[range])
            return .installed(version: version, matches: version == spec.version)

        } catch {
            return .versionCheckFailed(error: error.localizedDescription)
        }
    }

    /// Check all tools and return their statuses
    static func checkAllTools(config: ToolsConfiguration) -> [(name: String, spec: ToolsConfiguration.ToolSpec, status: ToolStatus)] {
        return config.tools.map { name, spec in
            (name: name, spec: spec, status: checkTool(name: name, spec: spec))
        }.sorted { $0.name < $1.name }
    }

    /// Install a tool using Homebrew
    static func installTool(name: String, spec: ToolsConfiguration.ToolSpec) throws {
        print("   Installing \(name) via brew...")
        let status = try runShellCommand("brew", arguments: ["install", spec.brew])

        guard status == 0 else {
            print("   ❌ Failed to install \(name)")
            throw ExitCode(status)
        }
    }

    /// Upgrade a tool to the pinned version using Homebrew
    static func upgradeTool(name: String, spec: ToolsConfiguration.ToolSpec) throws {
        print("   Upgrading \(name) to \(spec.version) via brew...")

        // First try upgrade
        var status = try runShellCommand("brew", arguments: ["upgrade", spec.brew])

        // If upgrade fails (already latest or not installed via brew), try reinstall
        if status != 0 {
            print("   Attempting reinstall...")
            status = try runShellCommand("brew", arguments: ["reinstall", spec.brew])
        }

        guard status == 0 else {
            print("   ❌ Failed to upgrade \(name)")
            throw ExitCode(status)
        }
    }

    /// Print tool status with formatting
    static func printToolStatus(name: String, spec: ToolsConfiguration.ToolSpec, status: ToolStatus) {
        switch status {
        case .installed(let version, let matches):
            if matches {
                print("   ✅ \(name): \(version)")
            } else {
                print("   ⚠️  \(name): \(version) (expected \(spec.version))")
            }
        case .notInstalled:
            print("   ❌ \(name): not installed (required \(spec.version))")
        case .versionCheckFailed(let error):
            print("   ⚠️  \(name): version check failed - \(error)")
        }
    }
}
