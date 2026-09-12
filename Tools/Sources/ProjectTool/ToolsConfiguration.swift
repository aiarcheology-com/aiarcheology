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
        let bundleDir: String?  // Optional: directory containing the binary and its resources (e.g., "bin" for SwiftGen)
        let sha256: String?  // Optional SHA256 checksum for integrity verification

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

    /// Returns the install path for standalone binaries.
    /// Prefers /usr/local/bin if writable, otherwise falls back to ~/.local/bin
    static func getInstallPath() throws -> String {
        let systemPath = "/usr/local/bin"
        let userPath = NSHomeDirectory() + "/.local/bin"

        // Check if /usr/local/bin is writable
        if FileManager.default.isWritableFile(atPath: systemPath) {
            return systemPath
        }

        // Create ~/.local/bin if it doesn't exist
        if !FileManager.default.fileExists(atPath: userPath) {
            do {
                try FileManager.default.createDirectory(atPath: userPath, withIntermediateDirectories: true)
            } catch {
                print("❌ Failed to create directory at \(userPath): \(error.localizedDescription)")
                print("   Please check directory permissions.")
                throw ExitCode.failure
            }
        }

        return userPath
    }

    /// Returns the install path for bundled tools (tools that need their resource bundles).
    /// Always uses ~/.local/lib/<toolname>/ to keep bundles organized
    static func bundledToolPath(for toolName: String) throws -> String {
        let basePath = NSHomeDirectory() + "/.local/lib"
        let toolPath = basePath + "/" + toolName

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: toolPath) {
            do {
                try FileManager.default.createDirectory(atPath: toolPath, withIntermediateDirectories: true)
            } catch {
                print("❌ Failed to create directory at \(toolPath): \(error.localizedDescription)")
                print("   Please check directory permissions.")
                throw ExitCode.failure
            }
        }

        return toolPath
    }

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
        // Determine the command to check version
        var versionCommand = spec.versionCommand

        // For bundled tools, check the bundled location first
        if let bundleDir = spec.bundleDir,
           let toolPath = try? bundledToolPath(for: name) {
            let bundledBinaryPath = toolPath + "/" + bundleDir + "/" + spec.binaryName
            if FileManager.default.fileExists(atPath: bundledBinaryPath) {
                // Use the bundled binary for version check, preserving configured flags
                let components = spec.versionCommand.split(whereSeparator: { $0.isWhitespace })
                if components.count <= 1 {
                    // No arguments configured; just use the bundled binary path
                    versionCommand = bundledBinaryPath
                } else {
                    // Replace the command name with the bundled path, keep all original arguments
                    let arguments = components.dropFirst()
                    versionCommand = bundledBinaryPath + " " + arguments.joined(separator: " ")
                }
            } else {
                // Check if command exists in PATH as fallback
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
            }
        } else {
            // Check if command exists in PATH
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
        }

        // Get version
        let versionTask = Process()
        versionTask.executableURL = URL(fileURLWithPath: "/bin/bash")
        versionTask.arguments = ["-c", versionCommand]

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
        // Retry transient network failures: a single connection reset from the release host used to
        // abort the whole CI build (`curl (35) Recv failure`), because the caller runs under
        // `set -eo pipefail`. `--retry-connrefused` also covers a refused TCP handshake, which a
        // bare `--retry` does not treat as retryable.
        let curlStatus = try runShellCommand("curl", arguments: [
            "-fsSL", "--retry", "3", "--retry-connrefused", "--retry-delay", "2",
            "-o", downloadPath.path, url
        ])

        guard curlStatus == 0 else {
            print("   ❌ Failed to download \(name)")
            throw ExitCode(curlStatus)
        }

        // Verify SHA256 checksum if provided
        if let expectedSHA256 = spec.sha256 {
            print("   Verifying SHA256 checksum...")
            let actualSHA256 = try computeSHA256(of: downloadPath.path)
            
            guard actualSHA256 == expectedSHA256 else {
                print("   ❌ SHA256 checksum mismatch!")
                print("      Expected: \(expectedSHA256)")
                print("      Actual:   \(actualSHA256)")
                print("   ⚠️  This could indicate a compromised download or outdated checksum.")
                throw ExitCode.failure
            }
            print("   ✅ SHA256 checksum verified")
        } else {
            print("   ⚠️  No SHA256 checksum provided - skipping integrity verification")
        }

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

            // Handle bundled tools differently (e.g., SwiftGen needs its resource bundle)
            if let bundleDir = spec.bundleDir {
                let sourceBundleDir = unzipDir.appendingPathComponent(bundleDir)
                
                // Verify bundleDir exists in the downloaded archive
                guard FileManager.default.fileExists(atPath: sourceBundleDir.path) else {
                    print("   ❌ Expected bundle directory '\(bundleDir)' not found in archive")
                    print("   📂 Archive structure (at \(unzipDir.path)):")
                    if let contents = try? FileManager.default.contentsOfDirectory(atPath: unzipDir.path) {
                        for item in contents {
                            let itemPath = unzipDir.appendingPathComponent(item).path
                            var isDirectory: ObjCBool = false
                            if FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDirectory) {
                                let typeIndicator = isDirectory.boolValue ? "📁" : "📄"
                                print("      \(typeIndicator) \(item)")
                            }
                        }
                    }
                    print("   ⚠️  The archive structure doesn't match the expected format.")
                    print("      Expected to find a '\(bundleDir)' directory containing '\(spec.binaryName)'")
                    throw ExitCode.failure
                }
                
                let destBundleDir = try bundledToolPath(for: name) + "/" + bundleDir

                // Remove existing bundle directory if present
                if FileManager.default.fileExists(atPath: destBundleDir) {
                    try FileManager.default.removeItem(atPath: destBundleDir)
                }

                // Copy entire bundle directory
                try FileManager.default.copyItem(atPath: sourceBundleDir.path, toPath: destBundleDir)

                // Make the binary executable
                let binaryPath = destBundleDir + "/" + spec.binaryName
                let chmodStatus = try runShellCommand("chmod", arguments: ["+x", binaryPath])
                guard chmodStatus == 0 else {
                    print("   ❌ Failed to set executable permission")
                    throw ExitCode(chmodStatus)
                }

                print("   ✅ Installed \(name) v\(spec.version) to \(destBundleDir)")
                return
            }

            // Standard binary installation
            let destPath = "\(try getInstallPath())/\(spec.binaryName)"

            // Find the binary in the unzipped contents
            let binaryPath = try findBinary(named: spec.binaryName, in: unzipDir)

            // Move to install path
            try installBinary(from: binaryPath, to: destPath)

            print("   ✅ Installed \(name) v\(spec.version) to \(destPath)")
            printPathWarningIfNeeded(destPath)

        case "binary":
            let destPath = "\(try getInstallPath())/\(spec.binaryName)"
            // Direct binary download - just move and chmod
            try installBinary(from: downloadPath.path, to: destPath)

            print("   ✅ Installed \(name) v\(spec.version) to \(destPath)")
            printPathWarningIfNeeded(destPath)

        default:
            print("   ❌ Unknown download type: \(spec.downloadType)")
            throw ExitCode.failure
        }
    }

    /// Print a warning if the tool was installed to a user directory that may need PATH update
    private static func printPathWarningIfNeeded(_ destPath: String) {
        let userPath = NSHomeDirectory() + "/.local/bin"
        if destPath.hasPrefix(userPath) {
            print("   💡 Note: Installed to ~/.local/bin - ensure it's in your PATH")
        }
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

    /// Compute SHA256 checksum of a file
    private static func computeSHA256(of filePath: String) throws -> String {
        let shaTask = Process()
        shaTask.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        shaTask.arguments = ["-a", "256", filePath]

        let pipe = Pipe()
        shaTask.standardOutput = pipe

        try shaTask.run()
        shaTask.waitUntilExit()

        guard shaTask.terminationStatus == 0 else {
            print("   ❌ Failed to compute SHA256 checksum")
            throw ExitCode(shaTask.terminationStatus)
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // shasum output format: "hash  filename"
        if let hash = output?.components(separatedBy: " ").first {
            return hash
        }

        throw ExitCode.failure
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
