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

	func signIn(emailAddress: String, code: String) async throws {
		throw ProgrammaticSignInError.unsupported
	}
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
		sut.purgeCloudData = { [provider] _ in
			provider?.recordPurge()
			return true
		}

		try await sut.deleteAccount()

		XCTAssertEqual(provider.steps, [.purge, .deleteClerkUser])
		XCTAssertEqual(sut.gate, .signedOut)
	}

	func testAFailedPurgeLeavesTheAccountAlone() async throws {
		// A purge is a list-and-delete loop and can stop half way. Deleting the account anyway
		// would strand whatever was left, so the user keeps an account they can retry with.
		struct PurgeIncomplete: Error {}
		sut.purgeCloudData = { _ in throw PurgeIncomplete() }

		do {
			try await sut.deleteAccount()
			XCTFail("deletion should not proceed when the purge did not finish")
		} catch let failure as AccountDeletionFailure {
			// Named, not generic: this stage is the one where nothing has been erased, and the
			// copy the user reads says so (AIA-0816).
			guard case let .purge(underlying) = failure else {
				return XCTFail("a purge failure must be reported as .purge, not \(failure)")
			}
			XCTAssertTrue(underlying is PurgeIncomplete, "the original error must survive the wrap")
		}

		XCTAssertEqual(provider.steps, [], "the Clerk account must not have been touched")
		XCTAssertTrue(provider.isSignedIn)
	}

	func testAFailedAccountDeletionIsReportedAsTheLaterStage() async throws {
		// The stage matters to the user, not just to us: here the cloud copy is already gone and
		// only the account survives, so copy promising that nothing was removed would be false.
		sut.purgeCloudData = { [provider] _ in
			provider?.recordPurge()
			return true
		}
		provider.deletionShouldFail = true

		do {
			try await sut.deleteAccount()
			XCTFail("deletion should throw when the account itself cannot be deleted")
		} catch let failure as AccountDeletionFailure {
			guard case let .accountDeletion(underlying, cloudDataErased) = failure else {
				return XCTFail("a Clerk failure must be reported as .accountDeletion, not \(failure)")
			}
			XCTAssertTrue(underlying is AuthValidationError, "the original error must survive the wrap")
			XCTAssertTrue(cloudDataErased, "a purge did run, so the copy may say the back-up is gone")
		}

		XCTAssertEqual(provider.steps, [.purge, .deleteClerkUser], "the purge still ran first")
		XCTAssertTrue(provider.isSignedIn, "the account outlives a failed deletion")
	}

	func testAWiredPurgeWithNobodySignedInRefusesToDelete() async throws {
		// The purge would erase nothing and say so; deleting the account anyway would destroy the
		// only credential that can reach whatever is stored (review of #818).
		provider.accountIdentifier = nil
		sut.purgeCloudData = { [provider] _ in
			provider?.recordPurge()
			return false
		}

		do {
			try await sut.deleteAccount()
			XCTFail("deletion must refuse when the cloud copy cannot be reached")
		} catch let failure as AccountDeletionFailure {
			guard case .purge = failure else {
				return XCTFail("refusing to reach the cloud is a purge-stage failure, not \(failure)")
			}
		}

		XCTAssertEqual(provider.steps, [], "neither half may run")
		XCTAssertTrue(provider.isSignedIn)
	}

	func testWithoutSyncConfiguredDeletionStillWorks() async throws {
		// A build with no Worker has nothing stored to erase; account deletion must not depend on it.
		try await sut.deleteAccount()
		XCTAssertEqual(provider.steps, [.deleteClerkUser])
	}
}

final class DeleteAccountFailureCopyTests: XCTestCase {
	func testPurgeFailureSaysTheEraseMayBeIncomplete() {
		let message = DeleteAccountView.deletionFailureMessage(
			for: .purge(NSError(domain: "test", code: 1))
		)
		XCTAssertEqual(message, L10n.Auth.Account.Delete.failedPurge)
	}

	func testAccountDeletionFailureAfterAnEraseSaysTheAccountSurvived() {
		let message = DeleteAccountView.deletionFailureMessage(
			for: .accountDeletion(NSError(domain: "test", code: 1), cloudDataErased: true)
		)
		XCTAssertEqual(message, L10n.Auth.Account.Delete.failedDeletion)
	}

	func testAccountDeletionWithNothingToEraseDoesNotClaimABackupWasRemoved() {
		let message = DeleteAccountView.deletionFailureMessage(
			for: .accountDeletion(NSError(domain: "test", code: 1), cloudDataErased: false)
		)
		XCTAssertEqual(message, L10n.Auth.Account.Delete.failedNothingErased)
	}
}
