//
//  ASCCredentialsSupport.swift
//  ProjectToolCore
//
//  Pure (filesystem-free, subprocess-free) logic behind `ProjectTool asc credentials`.
//  It lives in a library target so it can be unit tested — a test target cannot
//  `@testable import` an executable target.
//

import Foundation

// MARK: - Errors

public enum ASCCredentialsError: Error, CustomStringConvertible, Equatable {

    case missingReference(name: String)
    case unsafeIdentifier(name: String, value: String)
    case notAnOnePasswordReference(name: String, value: String)

    public var description: String {
        switch self {
        case .missingReference(let name):
            return "\(name) is missing from the credentials file."
        case .unsafeIdentifier(let name, let value):
            return """
                \(name) is not a safe identifier: '\(value)'. \
                Expected only letters, digits and '-' (the key id also becomes a filename).
                """
        case .notAnOnePasswordReference(let name, let value):
            return "\(name) is not an op:// reference: '\(value)'."
        }
    }
}

// MARK: - Parsed references

/// The three 1Password references `deliver.sh` needs, as written in `ios/asc.env`.
public struct ASCReferences: Equatable {
    public let keyID: String
    public let issuerID: String
    public let keyRef: String

    public init(keyID: String, issuerID: String, keyRef: String) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.keyRef = keyRef
    }
}

// MARK: - Support

public enum ASCCredentialsSupport {

    /// Names of the files written into `ios/asc.auth/`. Deliberately three plain single-line files
    /// rather than one shell-sourceable env file: `deliver.sh` reads them with `$(<file)`, so there
    /// is no parsing step and nothing that could be executed if the file were ever tampered with.
    public static let keyIDFileName = "key-id"
    public static let issuerIDFileName = "issuer-id"

    /// `altool` locates the key by name in its private-keys directory, so the filename is part of
    /// the contract — not a free choice.
    public static func keyFileName(forKeyID keyID: String) -> String {
        "AuthKey_\(keyID).p8"
    }

    /// Parses the `export NAME='value'` lines of an `asc.env`-shaped file.
    ///
    /// This is a deliberately narrow reader, not a shell interpreter: it understands the exact
    /// shape the committed template produces and ignores everything else. It never evaluates.
    public static func parseEnvironmentFile(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[line.startIndex ..< separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            // Strip one matching pair of surrounding quotes, if present.
            for quote in ["'", "\""] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
                value = String(value.dropFirst().dropLast())
                break
            }
            guard !name.isEmpty else { continue }
            values[name] = value
        }
        return values
    }

    /// Pulls the three references out of a parsed `asc.env` and checks each is an `op://` reference.
    public static func references(from values: [String: String]) throws -> ASCReferences {
        func reference(_ name: String) throws -> String {
            guard let value = values[name], !value.isEmpty else {
                throw ASCCredentialsError.missingReference(name: name)
            }
            guard value.hasPrefix("op://") else {
                throw ASCCredentialsError.notAnOnePasswordReference(name: name, value: value)
            }
            return value
        }
        return ASCReferences(
            keyID: try reference("ASC_KEY_ID"),
            issuerID: try reference("ASC_ISSUER_ID"),
            keyRef: try reference("ASC_KEY_OP_REF")
        )
    }

    /// Validates a value that 1Password resolved to.
    ///
    /// The key id is interpolated into a **filename**, so this is a path-traversal boundary, not
    /// cosmetic tidiness: a resolved value of `../../../../tmp/evil` must not be able to steer the
    /// write. Apple's key ids are 10 alphanumerics and issuer ids are UUIDs, so the permitted set is
    /// letters, digits and `-`.
    public static func validateResolvedIdentifier(_ value: String, name: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !trimmed.isEmpty,
            trimmed.count <= 64,
            trimmed.unicodeScalars.allSatisfy({ permitted.contains($0) })
        else {
            throw ASCCredentialsError.unsafeIdentifier(name: name, value: value)
        }
        return trimmed
    }

    /// A resolved `.p8` must look like a PKCS#8 private key. Guards against silently persisting a
    /// 1Password error string, an empty read, or the wrong attachment — all of which would
    /// otherwise only surface as an opaque failure much later, mid-upload.
    public static func isPlausiblePKCS8PrivateKey(_ contents: String) -> Bool {
        contents.contains("-----BEGIN PRIVATE KEY-----")
            && contents.contains("-----END PRIVATE KEY-----")
    }
}
