//
//  ASCCredentialsSupportTests.swift
//  ProjectToolCoreTests
//
//  Behavioural tests for the pure logic behind `ProjectTool asc credentials` (AIA-0475).
//  The security-relevant assertions are the identifier validation ones: the resolved key id is
//  interpolated into a filename, so it is a path-traversal boundary.
//

import XCTest
@testable import ProjectToolCore

final class ASCCredentialsSupportTests: XCTestCase {

    // MARK: - Parsing

    /// The exact shape of the committed `ios/asc.env.template`, verbatim.
    private let templateShaped = """
        # ios/asc.env — App Store Connect delivery credentials (1Password references). Gitignored.
        # deliver.sh sources this automatically.
        export ASC_KEY_ID='op://Personal/App Store Connect API Key/key id'
        export ASC_ISSUER_ID='op://Personal/App Store Connect API Key/Issuer ID'
        export ASC_KEY_OP_REF='op://Personal/App Store Connect API Key/AuthKey_62BW4FH93L.p8'
        """

    func testParsesTheCommittedTemplateShape() throws {
        let values = ASCCredentialsSupport.parseEnvironmentFile(templateShaped)
        let references = try ASCCredentialsSupport.references(from: values)

        XCTAssertEqual(references.keyID, "op://Personal/App Store Connect API Key/key id")
        XCTAssertEqual(references.issuerID, "op://Personal/App Store Connect API Key/Issuer ID")
        XCTAssertEqual(references.keyRef, "op://Personal/App Store Connect API Key/AuthKey_62BW4FH93L.p8")
    }

    func testIgnoresCommentsAndBlankLines() {
        let values = ASCCredentialsSupport.parseEnvironmentFile(
            """

            # ASC_KEY_ID='op://commented/out'

            export ASC_KEY_ID='op://real/value'
            """
        )
        XCTAssertEqual(values["ASC_KEY_ID"], "op://real/value")
        XCTAssertEqual(values.count, 1, "a commented-out assignment must not become a value")
    }

    func testAcceptsDoubleQuotedAndBareValues() {
        let values = ASCCredentialsSupport.parseEnvironmentFile(
            """
            export A="op://double/quoted"
            export B=op://bare
            C='op://no-export-keyword'
            """
        )
        XCTAssertEqual(values["A"], "op://double/quoted")
        XCTAssertEqual(values["B"], "op://bare")
        XCTAssertEqual(values["C"], "op://no-export-keyword")
    }

    func testValueContainingAnEqualsSignSurvives() {
        // op:// references may contain '='; splitting on the LAST '=' would corrupt them.
        let values = ASCCredentialsSupport.parseEnvironmentFile("export ASC_KEY_ID='op://v/item/a=b'")
        XCTAssertEqual(values["ASC_KEY_ID"], "op://v/item/a=b")
    }

    func testMissingReferenceIsReported() {
        let values = ASCCredentialsSupport.parseEnvironmentFile("export ASC_KEY_ID='op://only/one'")
        XCTAssertThrowsError(try ASCCredentialsSupport.references(from: values)) { error in
            XCTAssertEqual(error as? ASCCredentialsError, .missingReference(name: "ASC_ISSUER_ID"))
        }
    }

    func testLiteralValueIsRejectedAsAReference() {
        // `generate` materializes FROM 1Password; a literal value means there is nothing to resolve
        // and the operator should be told so rather than have a literal silently persisted.
        let values = ASCCredentialsSupport.parseEnvironmentFile(
            """
            export ASC_KEY_ID='62BW4FH93L'
            export ASC_ISSUER_ID='op://v/i/issuer'
            export ASC_KEY_OP_REF='op://v/i/key.p8'
            """
        )
        XCTAssertThrowsError(try ASCCredentialsSupport.references(from: values)) { error in
            XCTAssertEqual(
                error as? ASCCredentialsError,
                .notAnOnePasswordReference(name: "ASC_KEY_ID", value: "62BW4FH93L")
            )
        }
    }

    // MARK: - Identifier validation (path-traversal boundary)

    func testAcceptsRealisticAppleIdentifiers() throws {
        XCTAssertEqual(try ASCCredentialsSupport.validateResolvedIdentifier("62BW4FH93L", name: "k"), "62BW4FH93L")
        XCTAssertEqual(
            try ASCCredentialsSupport.validateResolvedIdentifier(
                "69a6de70-03db-47e3-e053-5b8c7c11a4d1", name: "i"),
            "69a6de70-03db-47e3-e053-5b8c7c11a4d1"
        )
    }

    func testTrimsSurroundingWhitespaceFromResolvedValues() throws {
        // `op read` output routinely carries a trailing newline; it must not reach the filename.
        XCTAssertEqual(try ASCCredentialsSupport.validateResolvedIdentifier("  62BW4FH93L\n", name: "k"), "62BW4FH93L")
    }

    func testRejectsIdentifiersThatCouldEscapeTheTargetDirectory() {
        for hostile in [
            "../../../../tmp/evil",
            "a/b",
            "..",
            ".",
            "key id",           // a space would break the altool filename contract
            "key;rm -rf /",
            "key$(whoami)",
            "key\nid",
            "",
            String(repeating: "a", count: 65)
        ] {
            XCTAssertThrowsError(
                try ASCCredentialsSupport.validateResolvedIdentifier(hostile, name: "ASC_KEY_ID"),
                "'\(hostile)' must be rejected before it can be interpolated into a filename"
            )
        }
    }

    // MARK: - Filename contract

    func testKeyFileNameMatchesTheAltoolContract() {
        // altool locates the key by this exact name in API_PRIVATE_KEYS_DIR.
        XCTAssertEqual(ASCCredentialsSupport.keyFileName(forKeyID: "62BW4FH93L"), "AuthKey_62BW4FH93L.p8")
    }

    // MARK: - Key body sanity

    func testAcceptsAPKCS8KeyBody() {
        let key = """
            -----BEGIN PRIVATE KEY-----
            MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg
            -----END PRIVATE KEY-----
            """
        XCTAssertTrue(ASCCredentialsSupport.isPlausiblePKCS8PrivateKey(key))
    }

    func testRejectsNonKeyBodies() {
        // The realistic failure: 1Password returns an error string, or the wrong attachment is
        // referenced. Persisting either would fail opaquely much later, mid-upload.
        XCTAssertFalse(ASCCredentialsSupport.isPlausiblePKCS8PrivateKey(""))
        XCTAssertFalse(ASCCredentialsSupport.isPlausiblePKCS8PrivateKey("[ERROR] could not read secret"))
        XCTAssertFalse(
            ASCCredentialsSupport.isPlausiblePKCS8PrivateKey("-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----")
        )
        XCTAssertFalse(
            ASCCredentialsSupport.isPlausiblePKCS8PrivateKey("-----BEGIN PRIVATE KEY-----\ntruncated"),
            "a truncated key must not pass"
        )
    }
}
