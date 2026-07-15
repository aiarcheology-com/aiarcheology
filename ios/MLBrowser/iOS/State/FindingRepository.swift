//
//  FindingRepository.swift
//  AI Archeology
//
//  AIA-0392: the Finding persist transaction, extracted out of SaveFindingSheet's View save().
//  One `save` intent; the SOLE production writer of finding screenshots — the single auditable
//  place for the on-device privacy invariant (enforced by an ArchitectureTests lint).
//

import Foundation
import CoreData
import UIKit

/// The metadata a saved finding carries from the editor form. Raw strings — the repository
/// applies the trim/normalize data rules, so the persisted values are the single source of truth.
struct FindingMetadata {
	let title: String
	let label: String
	let note: String
	let gps: String
}

/// The Core Data + screenshot-store repository for `Finding` rows.
///
/// Extracted from `SaveFindingSheet` (AIA-0392) so the persist transaction (PNG write → entity
/// create → lifecycle → validate → save → rollback) is unit-testable against Core Data + the
/// filesystem alone, with no View. Injected the SAME `DataController` as the rest of the graph, so
/// the write always targets the one store-backed `viewContext` — deterministically, regardless of
/// whether `@Environment(\.managedObjectContext)` crossed the presenting `.sheet` boundary.
///
/// **Privacy invariant (centralized here):** a finding screenshot is written only to the app's
/// local `Documents/Findings` (via `FindingScreenshotStore`) and is never transmitted off-device;
/// it leaves the device only through explicit user export (`FindingExporter`). This type is the
/// only production caller of `FindingScreenshotStore.save` — enforced by
/// `ArchitectureTests.testOnlyFindingRepositoryWritesScreenshots`.
@MainActor
final class FindingRepository {
	private let dataController: DataController

	init(dataController: DataController) {
		self.dataController = dataController
	}

	private var context: NSManagedObjectContext {
		dataController.container.viewContext
	}

	/// Persists one finding. PNG first, then the entity: a file without a row is self-healed by the
	/// orphan sweep, while a row without a file would be a broken finding. Any entity failure deletes
	/// both the pending object (it must not linger in the context for a later unrelated save to
	/// commit) and the PNG. Throws on either failure so the caller can surface the error UI.
	/// - Returns: the persisted, `.ready` finding.
	@discardableResult
	func save(capture: FindingCapture, image: UIImage, box: CGRect, metadata: FindingMetadata) throws -> Finding {
		let entityId = UUID()
		let filename: String
		do {
			filename = try FindingScreenshotStore.save(image, for: entityId)
		} catch {
			LoggingPolicy.error("Failed to write the finding screenshot", error: error, logger: .storage)
			throw error
		}

		let finding = Finding.create(in: context)
		finding.entityId = entityId
		finding.creationDate_ = .now
		finding.page = capture.pageURL
		finding.screenshotFilename = filename
		finding.title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
		finding.label_ = Self.normalized(metadata.label)
		finding.note_ = Self.normalized(metadata.note)
		finding.gps_ = Self.normalized(metadata.gps)
		finding.detectionClass = capture.observation.primaryLabelIdentifier
		finding.detectionConfidence = Double(capture.observation.labels.first?.confidence ?? capture.observation.confidence)
		finding.modelId = capture.params?.entityId
		finding.boxX = box.minX
		finding.boxY = box.minY
		finding.boxWidth = box.width
		finding.boxHeight = box.height

		finding.transition(to: .draft)
		do {
			try finding.throwIfInvalid()
			finding.transition(to: .ready)
			try Finding.save(in: context)
		} catch {
			let validationKeys = finding.validationReport().issues?.map(\.key).joined(separator: ", ") ?? "none"
			Finding.delete(finding, in: context)
			FindingScreenshotStore.delete(filename: filename)
			LoggingPolicy.error("Failed to save the finding (validation keys: \(validationKeys))", error: error, logger: .storage)
			throw error
		}

		return finding
	}

	/// Trim, then treat an all-whitespace field as absent (nil) — matches the former view helper.
	private static func normalized(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}
}
