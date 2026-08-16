//
//  SupportLog.swift
//  ProjectTool
//
//  The developer half of AIA-0643: mint the recipient keypair, and open the sealed `.aialog`
//  exports users send us. The app can only seal; nothing here ever ships in a build.
//

import Foundation
import ArgumentParser
import CryptoKit
import SupportLogFormat

// MARK: - support-log command group

struct SupportLog: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "support-log",
        abstract: "Mint the support-log keypair and open sealed .aialog exports.",
        discussion: """
            The app ships only the public key and can therefore encrypt but never decrypt.
            The private key lives in 1Password and is the only way to read an export.

              ProjectTool support-log keygen
              ProjectTool support-log decrypt report.aialog

            See Sources/SupportLogFormat for the container format.
            """,
        subcommands: [Keygen.self, Decrypt.self]
    )

    /// The 1Password field holding the current private key. Retired keys stay on the same item
    /// under their own fields, so an old export opens by pointing `--key-ref` at one of those.
    static let defaultPrivateKeyReference = "op://Personal/Support Log Decryption Key/private key"

    /// Checked when `--key-ref` is not supplied, so scripts and CI can pass a key without `op`.
    static let privateKeyEnvironmentVariable = "SUPPORT_LOG_PRIVATE_KEY"
}

// MARK: - support-log keygen

extension SupportLog {

    struct Keygen: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "keygen",
            abstract: "Mint an X25519 keypair for sealing support logs.",
            discussion: """
                Run this ONCE, offline, on a trusted Mac — never in CI. Put both halves on the
                1Password item, then commit only the public half to ios/MLBrowser-Info.plist.

                Rotating: mint a new pair, raise the key id, keep the retired PRIVATE key on the
                same item under its own field. Exports from older builds carry the old key id and
                keep opening; that is what makes rotation non-destructive.
                """
        )

        @Option(name: .customLong("key-id"), help: "The key id to record alongside the key (1–255).")
        var keyID: Int = 1

        func run() throws {
            guard let keyID = UInt8(exactly: keyID), keyID > 0 else {
                print("❌ --key-id must be between 1 and 255.")
                throw ExitCode.failure
            }
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let publicText = SupportLogKeyCoding.base64URLEncoded(privateKey.publicKey.rawRepresentation)
            let privateText = SupportLogKeyCoding.base64URLEncoded(privateKey.rawRepresentation)

            // Printed, never written to disk: a file would outlive this terminal and end up in a
            // backup. The operator pastes straight into 1Password.
            print("""

                Support-log keypair (X25519, base64url)
                =======================================

                key id      \(keyID)
                public key  \(publicText)
                private key \(privateText)

                1. Put ALL THREE on the 1Password item "Support Log Decryption Key",
                   as fields: `key id`, `public key`, `private key`.
                2. Commit ONLY the public key and the key id, to ios/MLBrowser-Info.plist:
                       <key>SupportLogPublicKey</key>
                       <string>\(publicText)</string>
                       <key>SupportLogKeyID</key>
                       <string>\(keyID)</string>
                3. The private key must never enter the repo, an xcconfig, Info.plist, CI, or
                   Xcode Cloud. Anyone holding it can read every export sealed to this key.

                The public key is not a secret: it ships in every binary and can only be used to
                encrypt a log TO us. Do not obfuscate it.

                """)
        }
    }
}

// MARK: - support-log decrypt

extension SupportLog {

    struct Decrypt: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "decrypt",
            abstract: "Open a sealed .aialog export and write the log it carries.",
            discussion: """
                  ProjectTool support-log decrypt report.aialog
                  ProjectTool support-log decrypt report.aialog --out report.txt
                  SUPPORT_LOG_PRIVATE_KEY=… ProjectTool support-log decrypt report.aialog

                The private key comes from 1Password by default. Metadata goes to stderr and the
                log to stdout, so `… decrypt r.aialog > r.txt` yields exactly the original bytes.
                """
        )

        @Argument(help: "The .aialog file to open.")
        var input: String

        @Option(name: .customLong("out"), help: "Write the log here instead of stdout.")
        var output: String?

        @Option(
            name: .customLong("key-ref"),
            help: "1Password reference for the private key. Ignored when \(SupportLog.privateKeyEnvironmentVariable) is set."
        )
        var keyReference: String?

        func run() throws {
            let envelope = try readEnvelope()

            // Reported before anything else: after a rotation we hold several private keys, and
            // choosing the wrong one fails identically to a corrupt file.
            let keyID = try envelope.keyIDOrExit()
            complain("key id: \(keyID)")

            let privateKey = try resolvePrivateKey()
            let opened: (metadata: SupportLogMetadata, log: Data)
            do {
                opened = try SupportLogEnvelope.open(envelope, with: privateKey)
            } catch let error as SupportLogEnvelope.FormatError {
                complain("❌ \(describe(error))")
                throw ExitCode.failure
            } catch {
                complain("""
                    ❌ Could not open the envelope: \(error)
                       The usual cause is the wrong private key. This file carries key id \(keyID);
                       point --key-ref at the field holding that key.
                    """)
                throw ExitCode.failure
            }

            let metadata = opened.metadata
            complain("""
                app:      \(metadata.app) (build \(metadata.build))
                date:     \(metadata.date)
                redacted: \(metadata.redacted)
                bytes:    \(opened.log.count)
                """)

            // The recovered bytes are UNTRUSTED. HPKE base mode does not authenticate the sender,
            // so anyone with the public key can mint a valid file. Write them out verbatim; never
            // interpret them, and never let this tool act on their contents.
            if let output {
                try opened.log.write(to: URL(fileURLWithPath: output), options: .atomic)
                complain("written to \(output)")
            } else {
                FileHandle.standardOutput.write(opened.log)
            }
        }

        private func readEnvelope() throws -> Data {
            do {
                return try Data(contentsOf: URL(fileURLWithPath: input))
            } catch {
                complain("❌ Could not read \(input): \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }

        /// The environment variable wins over `--key-ref` so a scripted run never blocks on an
        /// interactive 1Password unlock.
        private func resolvePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
            let encoded: String
            if let fromEnvironment = ProcessInfo.processInfo
                .environment[SupportLog.privateKeyEnvironmentVariable], fromEnvironment.isEmpty == false {
                encoded = fromEnvironment
            } else {
                let reference = keyReference ?? SupportLog.defaultPrivateKeyReference
                encoded = try Self.opRead(reference)
            }
            guard let key = SupportLogKeyCoding.privateKey(
                base64URLEncoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                complain("""
                    ❌ The private key is not a valid base64url X25519 key.
                       Expected \(SupportLogEnvelope.keyByteCount) bytes, as printed by
                       `ProjectTool support-log keygen`.
                    """)
                throw ExitCode.failure
            }
            return key
        }

        private func describe(_ error: SupportLogEnvelope.FormatError) -> String {
            switch error {
            case .tooShort:
                return "\(input) is too short to be a sealed support log."
            case .notASupportLog:
                return "\(input) is not a sealed support log (missing the AIALOG marker)."
            case .unsupportedVersion(let version):
                return "\(input) uses format version \(version); this build understands "
                    + "\(SupportLogEnvelope.formatVersion). Use a newer ProjectTool."
            case .malformedMetadata:
                return "The envelope opened but its metadata line is unreadable."
            case .payloadTooLarge(let count):
                return "The log inflated to \(count) bytes, over the "
                    + "\(SupportLogEnvelope.maximumInflatedByteCount)-byte limit. Refusing it."
            case .metadataContainsNewline:
                return "The metadata encoder emitted a newline; this file cannot be produced by a "
                    + "correct build."
            }
        }

        /// Reads one 1Password secret. Mirrors `ASCCredentials.opRead`: never echoes the value, and
        /// never echoes the reference, which names a vault and item.
        private static func opRead(_ reference: String) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["op", "read", reference]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.standardError

            do {
                try process.run()
            } catch {
                complain("❌ Could not run the 1Password CLI (`op`). Install it: brew install 1password-cli")
                throw ExitCode.failure
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                complain("""
                    ❌ `op read` failed for the support-log private key (exit \(process.terminationStatus)).
                       Unlock 1Password and retry: op signin
                       Or pass the key directly: \(SupportLog.privateKeyEnvironmentVariable)=…
                    """)
                throw ExitCode.failure
            }
            guard let value = String(data: data, encoding: .utf8), value.isEmpty == false else {
                complain("❌ `op read` returned nothing for the support-log private key.")
                throw ExitCode.failure
            }
            return value
        }
    }
}

/// Writes a diagnostic to **stderr**.
///
/// `print` would send it to stdout, which for `support-log decrypt` carries the recovered log
/// bytes — so `decrypt report.aialog > report.txt` would splice error text into the log the
/// operator is about to read. Everything except the log itself goes here.
func complain(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private extension Data {

    /// Reads the key id, turning a format problem into a clean exit rather than a stack trace.
    func keyIDOrExit() throws -> UInt8 {
        do {
            return try SupportLogEnvelope.keyID(of: self)
        } catch {
            complain("❌ Not a sealed support log: the AIALOG marker is missing or the file is truncated.")
            throw ExitCode.failure
        }
    }
}
