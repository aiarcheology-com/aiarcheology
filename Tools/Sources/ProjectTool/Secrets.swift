//
//  Secrets.swift
//  ProjectTool
//
//  Manages project secrets via 1Password CLI.
//

import Foundation
import ArgumentParser

// MARK: - Secrets Command Group

struct Secrets: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secrets",
        abstract: "Manage project secrets via 1Password.",
        discussion: """
            Secrets are stored in 1Password and injected into local config files.
            Template files (*.template.xcconfig) are committed to git.
            Generated files (Secrets.xcconfig, .sentryclirc) are gitignored.
            
            In CI (Xcode Cloud), secrets are injected via environment variables
            in ci_pre_xcodebuild.sh instead.
            """,
        subcommands: [Generate.self, Refresh.self, Validate.self, Clean.self],
        defaultSubcommand: Validate.self
    )
}

// MARK: - Path Configuration

extension Secrets {
    
    /// Paths relative to repository root
    enum Paths {
        static let template = "./ios/Secrets.template.xcconfig"
        static let output = "./ios/Secrets.xcconfig"
        static let sentryCLITemplate = "./ios/.sentryclirc.template"
        static let sentryCLIOutput = "./ios/.sentryclirc"
    }
    
    /// Check if running in CI environment
    static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil ||
        ProcessInfo.processInfo.environment["CI_XCODE_CLOUD"] != nil
    }
}

// MARK: - Generate Command

extension Secrets {
    
    /// Generate secrets files if they don't exist (first-time setup)
    struct Generate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "generate",
            abstract: "Generate secrets files from 1Password (if missing)."
        )
        
        func run() throws {
            if Secrets.isCI {
                print("⏭️  Skipping secrets generation in CI environment")
                return
            }
            
            let fileManager = FileManager.default
            var generated = false
            
            // Generate Secrets.xcconfig if missing
            if !fileManager.fileExists(atPath: Paths.output) {
                print("🔐 Generating Secrets.xcconfig from 1Password...")
                try generateXcconfig()
                generated = true
            } else {
                print("   ✓ Secrets.xcconfig already exists")
            }
            
            // Generate .sentryclirc if missing
            if !fileManager.fileExists(atPath: Paths.sentryCLIOutput) {
                print("🔐 Generating .sentryclirc from 1Password...")
                try injectFromTemplate(input: Paths.sentryCLITemplate, output: Paths.sentryCLIOutput)
                generated = true
            } else {
                print("   ✓ .sentryclirc already exists")
            }
            
            if generated {
                print("✅ Secrets generated successfully")
            } else {
                print("✅ All secrets files already exist (use 'secrets refresh' to regenerate)")
            }
        }
    }
}

// MARK: - Refresh Command

extension Secrets {
    
    /// Force regenerate all secrets from 1Password
    struct Refresh: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "refresh",
            abstract: "Force regenerate all secrets from 1Password."
        )
        
        func run() throws {
            if Secrets.isCI {
                print("⏭️  Skipping secrets refresh in CI environment")
                return
            }
            
            print("🔄 Refreshing all secrets from 1Password...")
            
            try generateXcconfig()
            print("   ✓ Secrets.xcconfig")
            
            try injectFromTemplate(input: Paths.sentryCLITemplate, output: Paths.sentryCLIOutput)
            print("   ✓ .sentryclirc")
            
            print("✅ All secrets refreshed")
        }
    }
}

// MARK: - Validate Command

extension Secrets {
    
    /// Validate that required secrets files exist
    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "validate",
            abstract: "Validate that required secrets files exist."
        )
        
        func run() throws {
            if Secrets.isCI {
                print("⏭️  Skipping secrets validation in CI environment")
                return
            }
            
            let fileManager = FileManager.default
            var missingFiles: [String] = []
            var missingTemplates: [String] = []
            
            // Check templates exist (should be committed)
            if !fileManager.fileExists(atPath: Paths.template) {
                missingTemplates.append(Paths.template)
            }
            if !fileManager.fileExists(atPath: Paths.sentryCLITemplate) {
                missingTemplates.append(Paths.sentryCLITemplate)
            }
            
            // Check generated files exist
            if !fileManager.fileExists(atPath: Paths.output) {
                missingFiles.append(Paths.output)
            }
            if !fileManager.fileExists(atPath: Paths.sentryCLIOutput) {
                missingFiles.append(Paths.sentryCLIOutput)
            }
            
            // Report missing templates (critical error)
            if !missingTemplates.isEmpty {
                print("❌ Missing template files (should be in git):")
                for file in missingTemplates {
                    print("   • \(file)")
                }
                throw ExitCode.failure
            }
            
            // Report missing generated files
            if !missingFiles.isEmpty {
                print("❌ Missing secrets files:")
                for file in missingFiles {
                    print("   • \(file)")
                }
                print("")
                print("   Run: swift run --package-path Tools ProjectTool secrets generate")
                throw ExitCode.failure
            }
            
            print("✅ All secrets files present")
        }
    }
}

// MARK: - Clean Command

extension Secrets {
    
    /// Remove generated secrets files
    struct Clean: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clean",
            abstract: "Remove generated secrets files."
        )
        
        func run() throws {
            let fileManager = FileManager.default
            var cleaned = false
            
            // Remove Secrets.xcconfig
            if fileManager.fileExists(atPath: Paths.output) {
                try fileManager.removeItem(atPath: Paths.output)
                print("   ✓ Removed Secrets.xcconfig")
                cleaned = true
            }
            
            // Remove .sentryclirc
            if fileManager.fileExists(atPath: Paths.sentryCLIOutput) {
                try fileManager.removeItem(atPath: Paths.sentryCLIOutput)
                print("   ✓ Removed .sentryclirc")
                cleaned = true
            }
            
            if cleaned {
                print("✅ Secrets cleaned")
            } else {
                print("✅ No secrets files to clean")
            }
        }
    }
}

// MARK: - Helpers

extension Secrets {
    
    /// Generate xcconfig file with proper escaping for URLs
    /// xcconfig treats // as a comment, so we need to escape it as $()/ 
    static func generateXcconfig() throws {
        // First verify template exists
        guard FileManager.default.fileExists(atPath: Paths.template) else {
            print("❌ Template file not found: \(Paths.template)")
            throw ExitCode.failure
        }
        
        // Inject secrets from 1Password
        let status = try runShellCommand("op", arguments: ["inject", "--force", "-i", Paths.template, "-o", Paths.output])
        
        guard status == 0 else {
            print("❌ Failed to inject secrets from \(Paths.template)")
            print("")
            print("   Troubleshooting:")
            print("   1. Ensure 1Password CLI is installed: brew install 1password-cli")
            print("   2. Sign in to 1Password: op signin")
            print("   3. Verify the template contains valid secret references")
            throw ExitCode(status)
        }
        
        // Post-process: escape // as $()/ for xcconfig compatibility
        // This is needed because xcconfig treats // as a comment delimiter
        var content = try String(contentsOfFile: Paths.output, encoding: .utf8)
        content = escapeUrlsForXcconfig(content)
        try content.write(toFile: Paths.output, atomically: true, encoding: .utf8)
    }
    
    /// Escape // in URLs to $()/$()/  for xcconfig compatibility
    /// xcconfig treats // as a comment, so each slash needs escaping
    /// e.g., https://example.com becomes https:$()/$()/example.com
    static func escapeUrlsForXcconfig(_ content: String) -> String {
        // Only escape // that follows a colon (i.e., in URLs like https://)
        // Don't escape // at the start of a line (comments)
        var result = content
        
        // Replace :// with :$()/$()/ (URL schemes) - each slash needs empty var prefix
        result = result.replacingOccurrences(of: "://", with: ":$()/$()/")
        
        return result
    }
    
    /// Inject secrets from a template file using 1Password CLI
    static func injectFromTemplate(input: String, output: String) throws {
        // First verify template exists
        guard FileManager.default.fileExists(atPath: input) else {
            print("❌ Template file not found: \(input)")
            throw ExitCode.failure
        }
        
        let status = try runShellCommand("op", arguments: ["inject", "--force", "-i", input, "-o", output])
        
        guard status == 0 else {
            print("❌ Failed to inject secrets from \(input)")
            print("")
            print("   Troubleshooting:")
            print("   1. Ensure 1Password CLI is installed: brew install 1password-cli")
            print("   2. Sign in to 1Password: op signin")
            print("   3. Verify the template contains valid secret references")
            throw ExitCode(status)
        }
    }
}
