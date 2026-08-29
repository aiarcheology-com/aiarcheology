//
//  PaywallAccountDeletionPromptTests.swift
//  AI ArcheologyTests
//
//  What the hard wall's delete-account confirmation says, and offers, when the device still holds
//  saved findings (AIA-0779).
//

import XCTest
@testable import ML_Browser

final class PaywallAccountDeletionPromptTests: XCTestCase {

	/// Nothing saved: the dialog is exactly what it was before AIA-0779. No export action, because
	/// an action that exports nothing is worse than none — it invites a tap that produces an empty
	/// archive on the screen a user is already anxious on.
	func testNothingSaved_warnsAboutBillingOnly() {
		let prompt = PaywallAccountDeletionPrompt.resolve(hasSavedFindings: false)

		XCTAssertEqual(prompt, .billingOnly)
		XCTAssertFalse(prompt.offersFindingsExport)
		XCTAssertEqual(prompt.message, L10n.Auth.Account.Delete.messageBilling)
	}

	/// The reported case: findings are on the device, the account is about to go, and the cloud copy
	/// goes with it. The dialog has to both say the device copy survives and offer to get it out.
	func testSavedFindings_offersExportAndSaysTheySurvive() {
		let prompt = PaywallAccountDeletionPrompt.resolve(hasSavedFindings: true)

		XCTAssertEqual(prompt, .billingAndFindings)
		XCTAssertTrue(prompt.offersFindingsExport)
		XCTAssertEqual(prompt.message, L10n.Auth.Account.Delete.messageBillingFindings)
	}

	/// The two branches must not be able to collapse into one string. A copy edit that made the
	/// findings message equal to the billing one would leave both tests above green while the
	/// screen said nothing new — the whole ticket.
	func testTheTwoMessagesAreDifferent() {
		XCTAssertNotEqual(
			PaywallAccountDeletionPrompt.billingOnly.message,
			PaywallAccountDeletionPrompt.billingAndFindings.message
		)
	}
}
