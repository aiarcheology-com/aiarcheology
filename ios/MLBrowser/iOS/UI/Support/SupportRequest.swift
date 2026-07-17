//
//  SupportRequest.swift
//  AI Archeology
//
//  Structured support requests (AIA-0440 Stage 1).
//

import Foundation

/// Builds the subject and body of a support email.
///
/// Deliberately a **pure value type**: no UIKit, no `@MainActor`, no I/O. Everything it needs is
/// injected, so the exact bytes a user would send are assertable in a unit test. That matters more
/// here than usual — this type decides what leaves the device, and the only honest way to claim
/// "it sends X and not Y" is a test that reads the output (the lesson of AIA-0441, where the
/// analytics allowlist was verifiable precisely because it was built from named fields).
///
/// ## Why prefilled diagnostics are not a privacy problem
///
/// Everything this builder emits lands in the **visible body** of a composer the user then reads,
/// edits and sends from their own mail account. Nothing rides along invisibly. That reviewability
/// — not omission — is what makes the request consent-clean, and it is why the web address is
/// included rather than withheld: a download or page bug without its URL is an unactionable report.
///
/// This is not in tension with AGENTS.md §10's "avoid logging full URLs that may contain sensitive
/// query parameters" — that rule governs **logs** (OSLog/Sentry), a channel the user never sees.
/// A support email the user reads before sending is the opposite case. Do not "fix" this by
/// stripping the URL; that would restore the bug it was added to solve.
///
/// A raw log tail is **not** included, and must not be: the user cannot review hundreds of lines in
/// a compose sheet, so attaching one would break the very property above. See AIA-0194.
struct SupportRequest {
	/// The support inbox. The one definition every surface uses — the Contact row that displays
	/// it, the composer that mails it, and the fallback copy that names it.
	static let supportEmailAddress = "info@aiarcheology.com"

	/// What the user says the request is about. Drives the subject's machine-readable tag.
	let category: SupportCategory

	/// The web address involved in the problem, when there is one — the page being browsed or the
	/// failing download. `nil` for requests with no web context (a billing question, say), and then
	/// the section is omitted entirely rather than rendered empty.
	let contextURL: String?

	/// The signed-in account identifier, when signed in. Already ours and already covered by
	/// privacy policy §3.1. Never a token.
	let accountID: String?

	/// The app's active language, e.g. "en".
	let appLanguage: String

	/// The app version, for at-a-glance triage in the subject line.
	let appVersion: String

	/// Pre-rendered device/app block from ``DeviceInfo/information()``, which is already a
	/// named-field allowlist: device model, OS version, app name/version/build, storage, date.
	/// Injected rather than fetched so this type stays pure and testable.
	let deviceInformation: String

	/// Carries the category's **stable rawValue tag**, not its localized name, so the support inbox
	/// can filter and label on it (AIA-0440 asks for exactly that) regardless of the sender's
	/// language. The human-readable name goes in the body.
	var subject: String {
		"ML Browser support [\(category.rawValue)] v\(appVersion)"
	}

	/// The composed body. The user's typing space comes **first** — a mail composer puts the cursor
	/// at the top, and burying the prompt under a diagnostics block is how you get empty reports.
	/// The details follow, visible and editable.
	var body: String {
		var lines: [String] = [
			L10n.Support.Body.describePrompt,
			"",
			"",
			"— — — — — — — — — — — — — — — —",
			L10n.Support.Body.detailsHeader,
			"",
			"\(L10n.Support.Body.category): \(category.displayName)"
		]
		if let contextURL, contextURL.isEmpty == false {
			lines.append("\(L10n.Support.Body.webAddress): \(contextURL)")
		}
		if let accountID, accountID.isEmpty == false {
			lines.append("\(L10n.Support.Body.account): \(accountID)")
		}
		lines.append("\(L10n.Support.Body.language): \(appLanguage)")
		lines.append(deviceInformation)
		return lines.joined(separator: "\n")
	}
}
