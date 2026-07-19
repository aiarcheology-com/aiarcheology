//
//  ASCCredentials.swift
//  ProjectTool
//
//  `ProjectTool asc credentials generate|refresh|status|clean` — materializes the App Store Connect
//  delivery credentials from 1Password ONCE into gitignored `ios/asc.auth/`, so `scripts/deliver.sh`
//  no longer depends on a live `op` session at an arbitrary moment during a long run (AIA-0475).
//
//  Mirrors the `secrets generate|refresh|clean` lifecycle deliberately: same verbs, same
//  skip-if-present semantics, so there is one mental model for "materialize a secret locally".
//
//  These are DELIVERY credentials. The .p8 is a private, account-level signing key that can upload
//  builds, read sales data and manage users — it must never become an input to the app build, and
//  in particular must never land in ios/Secrets.xcconfig.
//

import Foundation
import ArgumentParser
import ProjectToolCore

// MARK: - asc credentials

extension ASC {

    struct Credentials: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "credentials",
            abstract: "Materialize App Store Connect delivery credentials from 1Password.",
            discussion: """
                Resolves the op:// references in ios/asc.env once into gitignored ios/asc.auth/:

                  AuthKey_<KEYID>.p8   the private signing key (0600)
                  key-id               the App Store Connect API key id
                  issuer-id            the issuer id

                scripts/deliver.sh reads these directly, so a delivery no longer fails when the
                1Password session expires mid-run. Explicit ASC_* environment variables still win
                over both this directory and ios/asc.env.

                The .p8 is a private account-level key. It is NOT a build secret and never belongs
                in ios/Secrets.xcconfig.
                """,
            subcommands: [Generate.self, Refresh.self, Status.self, Clean.self],
            defaultSubcommand: Status.self
        )
    }
}

// MARK: - Paths

extension ASC.Credentials {

    /// Paths relative to the repository root (matching `Secrets.Paths`).
    enum Paths {
        static let envFile = "./ios/asc.env"
        static let directory = "./ios/asc.auth"

        static func keyID() -> String { "\(directory)/\(ASCCredentialsSupport.keyIDFileName)" }
        static func issuerID() -> String { "\(directory)/\(ASCCredentialsSupport.issuerIDFileName)" }
        static func key(forKeyID id: String) -> String {
            "\(directory)/\(ASCCredentialsSupport.keyFileName(forKeyID: id))"
        }
    }
}

// MARK: - Generate / Refresh

extension ASC.Credentials {

    struct Generate: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "generate",
            abstract: "Resolve credentials from 1Password if ios/asc.auth/ is not already populated."
        )

        func run() throws { try ASC.Credentials.materialize(force: false) }
    }

    struct Refresh: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "refresh",
            abstract: "Re-resolve credentials from 1Password, replacing ios/asc.auth/ (use after key rotation)."
        )

        func run() throws { try ASC.Credentials.materialize(force: true) }
    }
}

// MARK: - Status

extension ASC.Credentials {

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Report which credentials are materialized (never prints key material)."
        )

        func run() throws {
            guard let resolved = ASC.Credentials.materializedKeyID() else {
                print("⚠️  ios/asc.auth/ is not populated.")
                print("   Run: swift run --package-path Tools ProjectTool asc credentials generate")
                print("   (deliver.sh still works — it falls back to resolving op:// refs per run.)")
                return
            }
            // Printing the key id is deliberate: it is an identifier, not a secret, and it is the
            // only way an operator can notice that a ROTATED key left a stale file behind. Without
            // it, rotation surfaces as an opaque 401 in the middle of an upload.
            print("✅ App Store Connect credentials materialized in \(Paths.directory)")
            print("   key id: \(resolved)")
            print("   If the key was rotated, run: ProjectTool asc credentials refresh")
        }
    }
}

// MARK: - Clean

extension ASC.Credentials {

    struct Clean: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clean",
            abstract: "Remove ios/asc.auth/ and the private key it holds."
        )

        func run() throws {
            guard FileManager.default.fileExists(atPath: Paths.directory) else {
                print("✅ No App Store Connect credentials to clean")
                return
            }
            try FileManager.default.removeItem(atPath: Paths.directory)
            print("✅ Removed \(Paths.directory) (including the private .p8)")
        }
    }
}

// MARK: - Implementation

extension ASC.Credentials {

    /// The key id currently materialized, or `nil` if the directory is absent or incomplete.
    ///
    /// "Incomplete" counts as absent on purpose: a half-written directory must send the caller back
    /// to 1Password rather than fail later with a confusing missing-file error mid-delivery.
    static func materializedKeyID() -> String? {
        let fileManager = FileManager.default
        guard let id = try? String(contentsOfFile: Paths.keyID(), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty,
            fileManager.fileExists(atPath: Paths.issuerID()),
            fileManager.fileExists(atPath: Paths.key(forKeyID: id))
        else { return nil }
        return id
    }

    static func materialize(force: Bool) throws {
        if !force, let existing = materializedKeyID() {
            print("✅ App Store Connect credentials already present (key id \(existing))")
            print("   Use 'asc credentials refresh' to re-resolve them from 1Password.")
            return
        }

        guard FileManager.default.fileExists(atPath: Paths.envFile) else {
            print("❌ \(Paths.envFile) not found.")
            print("   Copy the template first: cp ios/asc.env.template ios/asc.env")
            throw ExitCode.failure
        }

        let contents = try String(contentsOfFile: Paths.envFile, encoding: .utf8)
        let references: ASCReferences
        do {
            references = try ASCCredentialsSupport.references(
                from: ASCCredentialsSupport.parseEnvironmentFile(contents))
        } catch {
            print("❌ \(Paths.envFile): \(error)")
            print("   'generate' materializes FROM 1Password, so all three values must be op:// references.")
            print("   If you already keep a .p8 on disk, set ASC_KEY_PATH instead — nothing to materialize.")
            throw ExitCode.failure
        }

        print("🔐 Resolving App Store Connect credentials from 1Password…")

        let keyID = try ASCCredentialsSupport.validateResolvedIdentifier(
            try opRead(references.keyID, describedAs: "ASC_KEY_ID"), name: "ASC_KEY_ID")
        let issuerID = try ASCCredentialsSupport.validateResolvedIdentifier(
            try opRead(references.issuerID, describedAs: "ASC_ISSUER_ID"), name: "ASC_ISSUER_ID")
        let keyBody = try opRead(references.keyRef, describedAs: "ASC_KEY_OP_REF")

        guard ASCCredentialsSupport.isPlausiblePKCS8PrivateKey(keyBody) else {
            print("❌ ASC_KEY_OP_REF did not resolve to a PKCS#8 private key.")
            print("   Expected a body delimited by -----BEGIN PRIVATE KEY-----.")
            print("   Check that the reference points at the AuthKey_<KEYID>.p8 attachment itself.")
            throw ExitCode.failure
        }

        // Replace wholesale rather than merge: a rotated key must not leave the previous
        // AuthKey_<OLDID>.p8 sitting alongside the new one.
        if FileManager.default.fileExists(atPath: Paths.directory) {
            try FileManager.default.removeItem(atPath: Paths.directory)
        }
        try FileManager.default.createDirectory(
            atPath: Paths.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        try write(keyBody, to: Paths.key(forKeyID: keyID))
        try write(keyID + "\n", to: Paths.keyID())
        try write(issuerID + "\n", to: Paths.issuerID())

        print("✅ Materialized into \(Paths.directory) (key id \(keyID))")
        print("   deliver.sh will now run without contacting 1Password.")
        print("   Remove it with: ProjectTool asc credentials clean")
    }

    /// Reads a single 1Password secret. Never echoes the value, and never echoes the command — the
    /// reference itself names a vault and item, which is not something to print into build logs.
    private static func opRead(_ reference: String, describedAs name: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["op", "read", reference]
        let stdout = Pipe()
        process.standardOutput = stdout
        // Let `op`'s own diagnostics reach the terminal; they are actionable ("not signed in") and
        // do not contain the secret.
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            print("❌ Could not run the 1Password CLI (`op`). Install it: brew install 1password-cli")
            throw ExitCode.failure
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            print("❌ `op read` failed for \(name) (exit \(process.terminationStatus)).")
            print("   Unlock 1Password and retry: op signin")
            throw ExitCode.failure
        }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            print("❌ `op read` returned nothing for \(name).")
            throw ExitCode.failure
        }
        return value
    }

    /// Creates the file 0600 *before* writing, so the contents are never briefly world-readable.
    private static func write(_ contents: String, to path: String) throws {
        let fileManager = FileManager.default
        guard fileManager.createFile(
            atPath: path,
            contents: Data(contents.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            print("❌ Could not write \(path)")
            throw ExitCode.failure
        }
    }
}
