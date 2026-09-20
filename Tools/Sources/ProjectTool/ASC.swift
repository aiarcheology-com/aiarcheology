//
//  ASC.swift
//  ProjectTool
//
//  App Store Connect helpers: credentials, Xcode Cloud observation, and ES256 API JWTs using
//  CryptoKit (no external interpreter). CryptoKit's ECDSA `.rawRepresentation` is already the
//  64-byte JOSE `r‖s` signature, so no DER→JOSE conversion is needed.
//

import Foundation
import ArgumentParser
import CryptoKit

// MARK: - asc command group

struct ASC: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "asc",
        abstract: "App Store Connect helpers.",
        subcommands: [Token.self, Credentials.self, Cloud.self]
    )
}

// MARK: - asc token

extension ASC {

    struct Token: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "token",
            abstract: "Print an App Store Connect API JWT (ES256) to stdout, or run --selftest.",
            discussion: """
                Loads a PKCS#8 .p8 private key and signs a team-key JWT
                (aud=appstoreconnect-v1, exp ≤ 20 min). Prints ONLY the token to stdout.

                  ProjectTool asc token --key-path AuthKey.p8 --key-id ABC123 --issuer <uuid> [--ttl 900]
                  ProjectTool asc token --selftest      # offline sign+verify with an ephemeral key
                """
        )

        @Option(name: .customLong("key-path"), help: "Path to the AuthKey_*.p8 file.")
        var keyPath: String?

        @Option(name: .customLong("key-id"), help: "App Store Connect API Key ID (JWT kid).")
        var keyID: String?

        @Option(name: .customLong("issuer"), help: "Issuer ID (team-wide UUID).")
        var issuer: String?

        @Option(name: .customLong("ttl"), help: "Token lifetime in seconds (max 1200; default 900).")
        var ttl: Int = 900

        @Flag(name: .customLong("selftest"), help: "Sign + verify with an ephemeral key; print ASC-JWT-SELFTEST-OK.")
        var selftest = false

        func run() throws {
            if selftest {
                let key = P256.Signing.PrivateKey()
                let token = try Token.sign(key: key, keyID: "SELFTEST", issuer: "selftest-issuer", ttl: 900)
                let parts = token.split(separator: ".", omittingEmptySubsequences: false)
                guard parts.count == 3 else { throw ValidationError("expected 3 JWT segments, got \(parts.count)") }
                let sigData = try Token.base64urlDecode(String(parts[2]))
                guard sigData.count == 64 else { throw ValidationError("signature is \(sigData.count) bytes, expected 64") }
                let signingInput = Data((parts[0] + "." + parts[1]).utf8)
                let sig = try P256.Signing.ECDSASignature(rawRepresentation: sigData)
                guard key.publicKey.isValidSignature(sig, for: signingInput) else {
                    throw ValidationError("self-test signature failed to verify")
                }
                print("ASC-JWT-SELFTEST-OK")
                return
            }

            guard ttl > 0, ttl <= 1200 else {
                throw ValidationError("--ttl must be between 1 and 1200 seconds (App Store Connect max is 20 min).")
            }
            guard let keyPath, let keyID, let issuer else {
                throw ValidationError("--key-path, --key-id and --issuer are required (or use --selftest).")
            }
            let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
            let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
            print(try Token.sign(key: key, keyID: keyID, issuer: issuer, ttl: ttl))
        }

        /// Build and sign a team-key App Store Connect JWT. Returns `header.claims.signature`.
        static func sign(key: P256.Signing.PrivateKey, keyID: String, issuer: String, ttl: Int) throws -> String {
            let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
            let now = Int(Date().timeIntervalSince1970)
            let claims: [String: Any] = [
                "iss": issuer,
                "iat": now,
                "exp": now + ttl,
                "aud": "appstoreconnect-v1"
            ]
            let signingInput = try base64url(JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
                + "." + base64url(JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys]))
            let signature = try key.signature(for: Data(signingInput.utf8))
            return signingInput + "." + base64url(signature.rawRepresentation)
        }

        static func base64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        static func base64urlDecode(_ string: String) throws -> Data {
            var b64 = string
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64) else { throw ValidationError("invalid base64url segment") }
            return data
        }
    }
}
