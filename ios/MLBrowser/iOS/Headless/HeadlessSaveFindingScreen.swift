//
//  HeadlessSaveFindingScreen.swift
//  AI Archeology
//
//  AIA-0975.
//

#if DEBUG
import Foundation
import HeadlessKit

/// The save-finding sheet over the web screen, for a detection picked with `pick`.
///
/// Reports the picked detection's label and confidence only — never its box or the image.
@MainActor
struct HeadlessSaveFindingScreen: HeadlessScreen {
	let parts: HeadlessAppParts
	let capture: StagedImageCapture
	/// Where `cancel` lands, asked for when the actions are listed: see
	/// `HeadlessRouteDecision.route(afterClosing:)`.
	let closeTarget: @MainActor () -> Route

	var route: Route { "save-finding" }

	/// A confidence as the headless build reports it: two decimals are enough to assert on, and a
	/// full `Float`-to-`Double` expansion would make scenarios compare noise.
	static func rounded(_ confidence: Double) -> Double {
		(confidence * 100).rounded() / 100
	}

	func state() -> JSONValue {
		guard let observation = capture.pendingCapture?.observation else { return [:] }
		return [
			"label": .string(observation.primaryLabelIdentifier ?? ""),
			"confidence": .number(Self.rounded(Double(observation.confidence)))
		]
	}

	func actions() -> [HeadlessAction] {
		let parts = parts
		let capture = capture
		let title = ParameterSpec("title", .string, summary: "The finding's name; required, as the sheet requires it.")
		let label = ParameterSpec("label", .string, required: false, summary: "The finding's label; empty by default.")
		return [
			// No `navigatesTo`: the save and the sync it awaits can raise the back-up question, so
			// where the dismissal lands is known only afterwards. The response carries the route.
			HeadlessAction(
				"save",
				summary: "Save the picked detection as a finding, then wait for the sync it triggers.",
				parameters: [title, label]
			) { arguments in
				try await Self.save(arguments: arguments, parts: parts, capture: capture)
			},
			HeadlessAction("cancel", summary: "Close the sheet without saving.", navigatesTo: closeTarget()) { _ in
				capture.cancel()
				return nil
			}
		]
	}

	private static func save(
		arguments: Arguments,
		parts: HeadlessAppParts,
		capture: StagedImageCapture
	) async throws -> JSONValue? {
		let title = try arguments.string("title")
		// The sheet disables Save until the title has text.
		guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
			throw HeadlessError(.invalidArgument, "'title' must not be empty")
		}
		let id: UUID
		do {
			id = try capture.save(title: title, label: arguments["label"]?.stringValue ?? "")
		} catch let failure as StagedImageCapture.Failure {
			throw HeadlessError(.actionFailed, "the finding could not be saved (\(failure.headlessName))")
		} catch {
			// Domain and code identify the failure; its message could carry a path.
			let nsError = error as NSError
			throw HeadlessError(.actionFailed, "the finding could not be saved (\(nsError.domain) \(nsError.code))")
		}
		// The save sets off a sync cycle; waiting for it means an upload has landed or failed before
		// the client reads the response. `syncNow()` returns the running cycle, queuing a follow-up if
		// one was already under way, so this cannot finish on work that predates the save.
		await parts.findingsSync.syncNow()?.value
		return ["id": .string(id.uuidString)]
	}
}
#endif
