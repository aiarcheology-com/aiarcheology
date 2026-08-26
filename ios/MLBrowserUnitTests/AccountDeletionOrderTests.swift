//
//  AccountDeletionOrderTests.swift
//  MLBrowserUnitTests
//
//  AIA-728: the cloud copy goes first, or it cannot be reached at all.
//

import XCTest
@testable import ML_Browser

/// Records the order in which deletion's two halves happen, and can fail either.
@MainActor
private final class RecordingAuthProvider: AuthProviding {
	enum Step: Equatable {
		case purge
		case deleteClerkUser
	}

	private(set) var steps: [Step] = []
	var deletionShouldFail = false

	var isSignedIn = true
	var accountIdentifier: String? = "user_2aaaaaaaaaaaaaaaaaaaaaaaaa"
	var displayName: String?

	func prepare() async {}
	func validateSession() async throws {}
	func sessionToken() async throws -> String? { "token" }
	func signOut() async { isSignedIn = false }

	func deleteAccount() async throws {
		steps.append(.deleteClerkUser)
		if deletionShouldFail { throw AuthValidationError.noValidSession }
		isSignedIn = false
	}

	func recordPurge() { steps.append(.purge) }
}

@MainActor
final class AccountDeletionOrderTests: XCTestCase {

	private var provider: RecordingAuthProvider!
	private var sut: AuthState!

	override func setUp() async throws {
		try await super.setUp()
		provider = RecordingAuthProvider()
		sut = AuthState(provider: provider)
	}

	func testTheCloudCopyIsErasedBeforeTheAccountThatCanReachIt() async throws {
		// Deleting the Clerk user first destroys the session token, and that token is the only
		// credential that can name this user's objects. Their findings — site coordinates attached
		// to a named person — would sit in the bucket for ever with nothing able to reach them.
		sut.purgeCloudData = { [provider] in provider?.recordPurge() }

		try await sut.deleteAccount()

		XCTAssertEqual(provider.steps, [.purge, .deleteClerkUser])
		XCTAssertEqual(sut.gate, .signedOut)
	}

	func testAFailedPurgeLeavesTheAccountAlone() async throws {
		// A purge is a list-and-delete loop and can stop half way. Deleting the account anyway
		// would strand whatever was left, so the user keeps an account they can retry with.
		struct PurgeIncomplete: Error {}
		sut.purgeCloudData = { throw PurgeIncomplete() }

		do {
			try await sut.deleteAccount()
			XCTFail("deletion should not proceed when the purge did not finish")
		} catch is PurgeIncomplete {
			// expected
		}

		XCTAssertEqual(provider.steps, [], "the Clerk account must not have been touched")
		XCTAssertTrue(provider.isSignedIn)
	}

	func testWithoutSyncConfiguredDeletionStillWorks() async throws {
		// A build with no Worker has nothing stored to erase; account deletion must not depend on it.
		try await sut.deleteAccount()
		XCTAssertEqual(provider.steps, [.deleteClerkUser])
	}
}
