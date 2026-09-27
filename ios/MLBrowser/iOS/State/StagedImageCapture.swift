//
//  StagedImageCapture.swift
//  AI Archeology
//
//  AIA-0975.
//

#if DEBUG
import Foundation
import UIKit

/// Detect on an image the headless launcher staged, pick a detection, and save it as a finding —
/// the find → save loop the web screen runs on a page snapshot, without the browser.
///
/// Headless-only, and owned by the headless application for the life of the process like its
/// `HeadlessPresentation`: nothing in the app proper creates one. It lives in the State layer
/// because it handles `UIImage`, which the headless adapters may not import.
///
/// Every step calls what the UI calls: `DeepDrivers.detect(on:tiling:)` and
/// `DetectionPresentation.filteredFrame(_:)` as the detection coordinator does, a `FindingCapture`
/// built from a displayed detection as the web screen builds one, and
/// `FindingRepository.save(capture:cropRect:metadata:)` as the save sheet does.
@MainActor
final class StagedImageCapture {

	/// One detection of the held frame, as a client picks it.
	struct Detection: Equatable {
		/// The position in ``detect(imageNamed:)``'s list, which `pick(index:)` takes.
		let index: Int
		/// The observation's primary label, or "" when the model reports none.
		let label: String
		/// The observation's own confidence — the value the threshold filters on and a finding stores.
		let confidence: Double
	}

	enum Failure: Error, Equatable {
		/// The name was not staged for this launch.
		case notStaged
		/// The name was staged, but no file is there.
		case missingFile
		/// The file is not an image `UIImage` can read.
		case undecodableImage
		/// `pick` before any detection frame is held.
		case noFrame
		/// `pick` with an index outside the held frame's detections.
		case detectionOutOfRange
		/// `save` without a picked detection.
		case noPendingCapture
	}

	/// Where the launcher copies staged images, inside the app's data container.
	static var defaultStagedDirectory: URL {
		URL.applicationSupportDirectory.appending(path: "Headless/Staged")
	}

	private let deep: DeepState
	private let settings: Settings
	private let repository: FindingRepository
	private let authState: AuthState
	private let stagedNames: [String]
	private let stagedDirectory: URL

	/// The last detection pass, filtered for display — what the web screen would be drawing.
	private(set) var frame: AppliedDetectionFrame?
	/// The picked detection: what the save sheet would be showing. Non-nil means the sheet is up.
	private(set) var pendingCapture: FindingCapture?
	/// The Author field's seed, read when the sheet opens, as the web screen hands the sheet
	/// `defaultAuthor` at presentation; the sheet never re-reads it.
	private var pendingAuthor = ""

	init(
		deep: DeepState,
		settings: Settings,
		repository: FindingRepository,
		authState: AuthState,
		stagedNames: [String],
		stagedDirectory: URL = StagedImageCapture.defaultStagedDirectory
	) {
		self.deep = deep
		self.settings = settings
		self.repository = repository
		self.authState = authState
		self.stagedNames = stagedNames
		self.stagedDirectory = stagedDirectory
	}

	/// Whether the launch staged anything to detect on.
	var hasStagedImages: Bool { stagedNames.isEmpty == false }

	/// Runs detection on a staged image with the registered drivers and holds the result as the
	/// displayed frame, dropping any pending capture.
	///
	/// - Returns: every displayed detection, in driver order as the frame lists them, then in each
	///   driver's own observation order. `pick(index:)` indexes this list.
	func detect(imageNamed name: String) async throws -> [Detection] {
		guard stagedNames.contains(name) else { throw Failure.notStaged }
		let url = stagedDirectory.appending(path: name, directoryHint: .notDirectory)
		// File IO and decoding stay off the main actor (ios/AGENTS.md §4).
		let image = try await Task.detached(priority: .userInitiated) { () throws -> UIImage in
			guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
				throw Failure.missingFile
			}
			guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else {
				throw Failure.undecodableImage
			}
			return image
		}.value

		// The two calls the web screen's detection coordinator makes for one pass.
		let results = await deep.drivers.detect(on: image, tiling: settings.tilingSchemes)
		let displayed = DetectionPresentation.filteredFrame(AppliedDetectionFrame(image: image, results: results))
		frame = displayed
		pendingCapture = nil
		return Self.flattened(displayed).enumerated().map { index, detection in
			Detection(
				index: index,
				label: detection.observation.primaryLabelIdentifier ?? "",
				confidence: Double(detection.observation.confidence)
			)
		}
	}

	/// Picks a detection of the held frame, as tapping its box on the web screen does, and holds
	/// the capture the save sheet would show.
	func pick(index: Int) throws {
		guard let frame else { throw Failure.noFrame }
		let detections = Self.flattened(frame)
		guard detections.indices.contains(index) else { throw Failure.detectionOutOfRange }
		let detection = detections[index]
		pendingCapture = FindingCapture(
			observation: detection.observation,
			params: detection.params,
			frame: frame,
			// A staged image comes from no page.
			pageURL: nil
		)
		pendingAuthor = authState.accountDisplayName ?? ""
	}

	/// The save sheet's Cancel.
	func cancel() {
		pendingCapture = nil
	}

	/// Saves the picked detection as a finding with the sheet's form values, then closes the sheet.
	///
	/// - Returns: the new finding's id.
	func save(title: String, label: String = "") throws -> UUID {
		guard let capture = pendingCapture else { throw Failure.noPendingCapture }
		// The sheet's own save call, with the unit rect: the full staged image and the detection's
		// own box. The sheet's crop editor frames the image from its on-screen viewport, which the
		// headless build does not have.
		let finding = try repository.save(
			capture: capture,
			cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
			metadata: FindingMetadata(
				title: title,
				label: label,
				note: "",
				// The sheet's seed for its Author field, taken when the sheet opened.
				author: pendingAuthor,
				gps: "",
				page: FindingPageURL.resolve(edited: "", captured: capture.pageURL)
			)
		)
		pendingCapture = nil
		return finding.entityId
	}

	/// The frame's detections in display order: each driver's group as the frame lists it, then
	/// that group's observations in order.
	private static func flattened(
		_ frame: AppliedDetectionFrame?
	) -> [(observation: DetectedObject, params: DeepDriverParams)] {
		(frame?.results ?? []).flatMap { group in
			group.observations.map { (observation: $0, params: group.params) }
		}
	}
}
#endif
