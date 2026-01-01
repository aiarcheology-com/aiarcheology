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
        let versionCommand: String
        let versionPattern: String
        let downloadUrl: String
        let downloadType: String  // "zip" or "binary"
        let binaryName: String

        /// Get the download URL with version interpolated
        func resolvedDownloadUrl() -> String {
            return downloadUrl.replacingOccurrences(of: "${version}", with: version)
        }
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
    static let installPath = "/usr/local/bin"

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

    /// Download and install a tool to the specified version
    static func installTool(name: String, spec: ToolsConfiguration.ToolSpec) throws {
        let url = spec.resolvedDownloadUrl()
        print("   Downloading \(name) v\(spec.version)...")
        print("   URL: \(url)")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Download the file
        let downloadPath = tempDir.appendingPathComponent("download")
        let curlStatus = try runShellCommand("curl", arguments: ["-fsSL", "-o", downloadPath.path, url])

        guard curlStatus == 0 else {
            print("   ❌ Failed to download \(name)")
            throw ExitCode(curlStatus)
        }

        let destPath = "\(installPath)/\(spec.binaryName)"

        switch spec.downloadType {
        case "zip":
            // Unzip and find the binary
            let unzipDir = tempDir.appendingPathComponent("unzipped")
            try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

            let unzipStatus = try runShellCommand("unzip", arguments: ["-q", downloadPath.path, "-d", unzipDir.path])
            guard unzipStatus == 0 else {
                print("   ❌ Failed to unzip \(name)")
                throw ExitCode(unzipStatus)
            }

            // Find the binary in the unzipped contents
            let binaryPath = try findBinary(named: spec.binaryName, in: unzipDir)

            // Move to install path
            try installBinary(from: binaryPath, to: destPath)

        case "binary":
            // Direct binary download - just move and chmod
            try installBinary(from: downloadPath.path, to: destPath)

        default:
            print("   ❌ Unknown download type: \(spec.downloadType)")
            throw ExitCode.failure
        }

        print("   ✅ Installed \(name) v\(spec.version) to \(destPath)")
    }

    /// Find a binary by name in a directory (recursive)
    private static func findBinary(named name: String, in directory: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isExecutableKey])

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent == name {
                return fileURL.path
            }
        }

        // If not found by exact name, look for any executable
        let findTask = Process()
        findTask.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        findTask.arguments = [directory.path, "-name", name, "-type", "f"]

        let pipe = Pipe()
        findTask.standardOutput = pipe

        try findTask.run()
        findTask.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let path = output, !path.isEmpty {
            return path.components(separatedBy: "\n").first ?? path
        }

        // Binary not found - provide detailed error information
        print("   ❌ Binary '\(name)' not found in unzipped directory: \(directory.path)")
        
        // List the contents of the directory to aid troubleshooting
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            print("   📂 Directory contents:")
            for item in contents {
                print("      - \(item)")
            }
        }
        
        throw ExitCode.failure
    }

    /// Install a binary to the destination path with proper permissions
    private static func installBinary(from sourcePath: String, to destPath: String) throws {
        // Remove existing binary if present
        if FileManager.default.fileExists(atPath: destPath) {
            try FileManager.default.removeItem(atPath: destPath)
        }

        // Copy to destination
        try FileManager.default.copyItem(atPath: sourcePath, toPath: destPath)

        // Make executable
        let chmodStatus = try runShellCommand("chmod", arguments: ["+x", destPath])
        guard chmodStatus == 0 else {
            print("   ❌ Failed to set executable permission")
            throw ExitCode(chmodStatus)
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
