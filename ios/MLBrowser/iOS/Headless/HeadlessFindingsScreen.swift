//
//  HeadlessFindingsScreen.swift
//  AI Archeology
//
//  AIA-0975.
//

#if DEBUG
import Foundation
import HeadlessKit

/// The findings list, a sheet over the open menu, opened from the drawer's Findings row.
///
/// Reports each finding's id, title, back-up state and whether its screenshot is on disk — never its
/// page URL, coordinates, notes, author, image data, or the account id.
@MainActor
struct HeadlessFindingsScreen: HeadlessScreen {
	let parts: HeadlessAppParts
	/// Where `close` lands, asked for when the actions are listed: see
	/// `HeadlessRouteDecision.route(afterClosing:)`.
	let closeTarget: @MainActor () -> Route

	var route: Route { "findings" }

	func state() -> JSONValue {
		let findingsSync = parts.findingsSync
		let findings: [JSONValue] = Self.listedFindings(in: parts).map { finding in
			[
				"id": .string(finding.entityId.uuidString),
				"title": .string(finding.displayTitle),
				"backup": .string(findingsSync.backupStates[finding.entityId].headlessName),
				"hasImage": .bool(Self.hasImage(finding))
			]
		}
		let usage: JSONValue = findingsSync.usage.map { usage in
			["used": .number(Double(usage.used)), "limit": .number(Double(usage.limit))]
		} ?? .null
		return [
			"findings": .array(findings),
			"usage": usage,
			"pendingUploadCount": .number(Double(findingsSync.pendingUploadCount)),
			"parkedCount": .number(Double(findingsSync.parkedCount))
		]
	}

	func actions() -> [HeadlessAction] {
		let parts = parts
		// The drawer's sheets: the model the drawer view binds to.
		let presentation = parts.chromeState.drawerPresentation
		let findingsSync = parts.findingsSync
		var actions = [
			HeadlessAction("close", summary: "Close the findings list.", navigatesTo: closeTarget()) { _ in
				presentation.isFindingsPresented = false
				return nil
			}
		]
		// Pull-to-refresh, which the list gates on a configured Worker.
		if findingsSync.isCloudConfigured {
			actions.append(HeadlessAction("refresh", summary: "Pull to refresh: run a sync cycle and wait for it.") { _ in
				await findingsSync.syncNow()?.value
				return nil
			})
		}
		// The Synchronize button, with a signed-in account to act for. Signed out it opens the
		// sign-in sheet instead, which the account screen covers.
		if HeadlessAccountScreen.isSignedIn(parts.authState),
		   findingsSync.isCloudConfigured,
		   let account = parts.authState.accountIdentifier {
			actions.append(HeadlessAction(
				"synchronize",
				summary: "Press Synchronize and wait for the outcome line."
			) { _ in
				try await Self.synchronize(account: account, findingsSync: findingsSync)
			})
		}
		let id = ParameterSpec("id", .string, summary: "The finding id, from state.findings.")
		actions.append(HeadlessAction(
			"delete",
			summary: "Delete a finding, then wait for the sync that sends its deletion.",
			parameters: [id]
		) { arguments in
			try await Self.delete(arguments: arguments, parts: parts)
		})
		return actions
	}

	/// The list's own fetch: the same request its `@FetchRequest` runs, in the same order.
	static func listedFindings(in parts: HeadlessAppParts) -> [Finding] {
		let context = parts.dataController.container.viewContext
		do {
			return try context.fetch(Finding.findingsListFetchRequest())
		} catch {
			LoggingPolicy.error("Headless findings list could not fetch findings", error: error, logger: .storage)
			return []
		}
	}

	/// Whether a ready finding with this id is in the local store: what `finding-present` and
	/// `finding-absent` wait on.
	static func isPresent(_ id: UUID, in parts: HeadlessAppParts) -> Bool {
		let context = parts.dataController.container.viewContext
		return Finding.select(id, in: context)?.lifeCycle == .ready
	}

	/// The id argument of an action or wait, or `invalidArgument` when it is not a UUID.
	static func findingID(_ arguments: Arguments) throws -> UUID {
		guard let id = UUID(uuidString: try arguments.string("id")) else {
			throw HeadlessError(.invalidArgument, "'id' is not a finding id")
		}
		return id
	}

	/// Whether the screenshot file the finding names is on disk. A row whose file is missing shows a
	/// placeholder; this is how a client sees that.
	private static func hasImage(_ finding: Finding) -> Bool {
		guard let filename = finding.screenshotFilename,
			  let url = FindingScreenshotStore.url(forFilename: filename) else { return false }
		return FileManager.default.fileExists(atPath: url.path)
	}

	/// The button's own call, then the outcome line it shows.
	private static func synchronize(account: String, findingsSync: FindingsSyncCoordinator) async throws -> JSONValue? {
		guard let task = findingsSync.synchronizeNow(expectedAccount: account) else {
			throw HeadlessError(.actionFailed, "the synchronize did not start")
		}
		await task.value
		// The task posts no outcome when no cycle ran (the account's cloud data is being erased) or
		// the account changed while it ran; the bar then shows no line either.
		guard let outcome = findingsSync.lastSynchronize else {
			throw HeadlessError(.actionFailed, "the synchronize finished without an outcome")
		}
		return ["outcome": .string(outcome.headlessName)]
	}

	/// The row's swipe-to-delete, then the sync its tombstone sets off: the deletion has been sent,
	/// or has failed to be, before the response.
	private static func delete(arguments: Arguments, parts: HeadlessAppParts) async throws -> JSONValue? {
		let id = try findingID(arguments)
		let context = parts.dataController.container.viewContext
		guard let finding = Finding.select(id, in: context), finding.lifeCycle == .ready else {
			throw HeadlessError(.invalidArgument, "no finding '\(id.uuidString)' in the list")
		}
		do {
			try parts.findingRepository.delete(finding)
		} catch {
			// Domain and code identify the failure; its message could carry a path.
			let nsError = error as NSError
			throw HeadlessError(.actionFailed, "the finding could not be deleted (\(nsError.domain) \(nsError.code))")
		}
		// `delete` already asked for a cycle; `syncNow()` returns that cycle, with a follow-up queued
		// if it was already running, so this cannot finish on work that predates the delete.
		await parts.findingsSync.syncNow()?.value
		return nil
	}
}

/// The back-up question, over the app proper: findings from before this account signed in wait for
/// the user to say whether they may be backed up.
///
/// Reports only how many findings the question is about.
@MainActor
struct HeadlessBackupConsentScreen: HeadlessScreen {
	let findingsSync: FindingsSyncCoordinator

	var route: Route { "backup-consent" }

	func state() -> JSONValue {
		["count": .number(Double(findingsSync.backupConsentRequest?.count ?? 0))]
	}

	func actions() -> [HeadlessAction] {
		// No `navigatesTo`: the next screen is whatever the card covered.
		[
			HeadlessAction("accept", summary: "Back these findings up, and wait for the upload it starts.") { [findingsSync] _ in
				try await Self.answer(accepted: true, findingsSync: findingsSync)
			},
			HeadlessAction("decline", summary: "Keep these findings on this device.") { [findingsSync] _ in
				try await Self.answer(accepted: false, findingsSync: findingsSync)
			}
		]
	}

	/// The card's own call, awaited: the answer has been applied — and on accept the upload tried —
	/// before the response.
	private static func answer(accepted: Bool, findingsSync: FindingsSyncCoordinator) async throws -> JSONValue? {
		// This screen exists only while a request is pending, so nil means the account signed in now
		// is not the one it asked about. The coordinator has dropped the question unanswered.
		guard let task = findingsSync.answerBackupConsent(accepted: accepted) else {
			throw HeadlessError(.actionFailed, "the answer was not applied: the question was for another account")
		}
		await task.value
		return nil
	}
}

// MARK: - Stable names for reported state

private extension FindingsSyncCoordinator.FindingBackupState? {
	/// `none` is the absence of an entry: nothing is shown on the row, as while signed out.
	var headlessName: String {
		switch self {
		case .backedUp: "backedUp"
		case .owed: "owed"
		case .keptOnDevice: "keptOnDevice"
		case nil: "none"
		}
	}
}

private extension FindingsSyncCoordinator.ManualBackupOutcome {
	var headlessName: String {
		switch self {
		case .succeeded: "succeeded"
		case .offline: "offline"
		case .quotaFull: "quotaFull"
		case .failed: "failed"
		}
	}
}
#endif
