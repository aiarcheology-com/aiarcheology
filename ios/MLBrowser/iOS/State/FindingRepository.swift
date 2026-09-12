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

	/// Removes every finding (AIA-0303, Settings → Reset → Remove Findings). Batch-deletes all
	/// `Finding` rows on a background context, merging the deletion into the live `viewContext` so
	/// an open `@FetchRequest` refreshes and no zombie rows can resurrect on a later save; then, and
	/// only if the row delete succeeded, sweeps the now-orphaned screenshot PNGs.
	///
	/// Mirrors `DemoDataManager.deleteBrowsingHistory()` but PROPAGATES the delete error instead of
	/// swallowing it, so the caller can surface it. The sweep is skipped when the delete throws (we
	/// must never remove screenshots for rows that are still present). The sweep itself stays
	/// best-effort — a leftover file self-heals on the next findings-list open
	/// (`FindingScreenshotStore.sweepOrphans` contract). `.mergeByPropertyStoreTrump` matches the
	/// history-delete precedent for parity only; a batch delete bypasses `context.save()`, so the
	/// background context's merge policy never actually fires.
	func removeAllFindings() async throws {
		LoggingPolicy.info("Removing all findings", logger: .storage)
		let viewContext = context
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			// The viewContext reference is only handed to mergeChanges(fromRemoteContextSave:into:),
			// which is safe to call cross-queue (same rationale as deleteBrowsingHistory).
			dataController.performBackgroundTask(mergePolicy: .mergeByPropertyStoreTrump) { bgContext in
				do {
					try Finding.deleteAll(in: bgContext, mergingInto: [viewContext])
					continuation.resume()
				} catch {
					LoggingPolicy.error("Failed to remove all findings", error: error, logger: .storage)
					continuation.resume(throwing: error)
				}
			}
		}
		// Reached only when the delete succeeded. After the merge above no finding references any
		// file, so every screenshot is now an orphan and is removed here (MainActor / viewContext).
		FindingScreenshotStore.sweepOrphans(in: viewContext)
	}

	/// Snapshots every stored finding for the export-before-delete flow (AIA-0303). Unlike
	/// `FindingsListView`'s `.ready`-only, filtered export, this includes ALL lifecycles: the delete
	/// that follows removes every row regardless of lifecycle, so the export must cover them too.
	func allFindingSnapshots() -> [FindingSnapshot] {
		Finding.selectAll(in: context).map(FindingSnapshot.init)
	}

	/// True if any finding exists — gates the "Export First…" action so an empty store never offers
	/// an empty archive (AIA-0303).
	func hasAnyFinding() -> Bool {
		Finding.count(in: context, predicate: nil) > 0
	}

	/// Trim, then treat an all-whitespace field as absent (nil) — matches the former view helper.
	private static func normalized(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}
}
