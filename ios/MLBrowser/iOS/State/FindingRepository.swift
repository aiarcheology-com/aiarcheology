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
	/// The finder's credit (AIA-0651). Deliberately declared WITHOUT a default: a `let` with an
	/// initializer is dropped from the memberwise init, which would silently ignore whatever every
	/// call site passed. Requiring it at each site is what makes the capture editor's value arrive.
	let author: String
	let gps: String
}

/// The Core Data + screenshot-store repository for `Finding` rows.
///
/// Extracted from `SaveFindingSheet` (AIA-0392) so the persist transaction (image write → entity
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

	/// Persists one finding. Image first, then the entity: a file without a row is self-healed by the
	/// orphan sweep, while a row without a file would be a broken finding. Any entity failure deletes
	/// both the pending object (it must not linger in the context for a later unrelated save to
	/// commit) and the image. Throws on either failure so the caller can surface the error UI.
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
		finding.author = Self.normalized(metadata.author)
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

	// MARK: - Archive import (AIA-713)

	/// What to do about a finding whose id the device already stores.
	enum DuplicatePolicy {
		/// Leave the stored finding exactly as it is.
		case skip
		/// Overwrite it with the archived one.
		case replace
	}

	/// The outcome of an import, in the terms the user is told about.
	struct ImportSummary: Equatable {
		var restored = 0
		var skipped = 0
		var failed = 0
	}

	/// Restores findings decoded by ``FindingArchiveImport`` into the store.
	///
	/// **Identity is resolved before any file is touched.** Screenshot filenames derive from the
	/// finding id, so writing an archived image before deciding skip-or-replace would overwrite the
	/// picture of a finding the user never agreed to change — and `Data.write(.atomic)` replaces
	/// silently. Every row therefore looks itself up first, and a `.skip` duplicate causes no file
	/// IO at all.
	///
	/// **A replaced finding is recoverable until the save commits.** The existing image is read into
	/// memory before the new one is written, and put back if the row fails validation or the
	/// terminal save throws. Without that, a failed replace leaves a row pointing at an image that
	/// was already overwritten.
	///
	/// Rows are inserted, validated and then committed in ONE save. A row that fails validation is
	/// removed (a new object) or reverted to its stored values (an existing one) and counted as
	/// failed, rather than being allowed to fail the whole save — `Finding.save(in:)` commits the
	/// entire context, so one bad row would otherwise discard every good one.
	///
	/// - Note: the caller must have decoded the archive OFF the MainActor; this method is the
	///   `viewContext` half and does no unzipping, parsing or image decoding.
	@discardableResult
	func importFindings(
		_ contents: FindingArchiveContents,
		duplicates: DuplicatePolicy
	) throws -> ImportSummary {
		var summary = ImportSummary()
		// Filename plus the bytes it held, for every image this import overwrote.
		var replacedImages: [(filename: String, data: Data?)] = []
		var writtenFilenames: [String] = []

		for row in contents.rows {
			let existing = Finding.select(row.id, in: context)
			if existing != nil, duplicates == .skip {
				summary.skipped += 1
				continue
			}

			var backup: (filename: String, data: Data?)?
			var filename: String?
			do {
				if let imageData = contents.images[row.id] {
					let ext = row.screenshotExtension ?? "jpg"
					if let previous = existing?.screenshotFilename,
						let previousURL = FindingScreenshotStore.url(forFilename: previous) {
						backup = (previous, try? Data(contentsOf: previousURL))
					}
					let written = try FindingScreenshotStore.save(imageData, for: row.id, pathExtension: ext)
					filename = written
					writtenFilenames.append(written)
					if let backup { replacedImages.append(backup) }
				} else {
					// No image in the archive: keep whatever the device already has for a replaced
					// finding, and give a new one the canonical name with no file behind it — a row
					// whose picture is missing is an already-supported state.
					filename = existing?.screenshotFilename ?? Finding.screenshotFilename(for: row.id)
				}

				let finding = existing ?? Finding.create(in: context)
				try apply(row, to: finding, screenshotFilename: filename)
				summary.restored += 1
			} catch {
				LoggingPolicy.warning(
					"Skipped a finding during import: \(error.localizedDescription)",
					logger: .storage
				)
				restore(backup)
				if let existing {
					// Never delete a finding the user already had because an archived copy was bad.
					context.refresh(existing, mergeChanges: false)
				} else if let pending = Finding.select(row.id, in: context) {
					context.delete(pending)
				}
				if let filename, backup == nil, existing == nil {
					FindingScreenshotStore.delete(filename: filename)
					writtenFilenames.removeAll { $0 == filename }
				}
				summary.failed += 1
			}
		}

		do {
			try Finding.save(in: context)
		} catch {
			// The whole transaction is gone, so every file this import wrote must go too, and every
			// image it replaced must come back.
			context.rollback()
			for filename in writtenFilenames {
				FindingScreenshotStore.delete(filename: filename)
			}
			for backup in replacedImages {
				restore(backup)
			}
			LoggingPolicy.error("Finding import failed to commit", error: error, logger: .storage)
			throw error
		}

		return summary
	}

	/// How many of an archive's findings this device already stores.
	///
	/// Lets the caller ask the skip-or-replace question ONCE, with a real number, instead of per
	/// finding or not at all. Read-only: nothing here writes, so asking is always safe.
	func duplicateCount(in contents: FindingArchiveContents) -> Int {
		contents.rows.count { Finding.select($0.id, in: context) != nil }
	}

	/// Writes one decoded row onto a finding and walks it through the lifecycle state machine.
	///
	/// The lifecycle goes through `transition(to:)` rather than assigning `lifeCycleString`:
	/// `.empty → .ready` is not an allowed transition, and setting the raw string would force past
	/// the guard exactly as a corrupt write does.
	private func apply(_ row: ImportedFindingRow, to finding: Finding, screenshotFilename: String?) throws {
		finding.entityId = row.id
		finding.title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
		finding.label_ = row.label
		finding.note_ = row.note
		finding.author = row.author
		finding.gps_ = row.gps
		finding.page = row.page
		finding.detectionClass = row.detectionClass
		finding.detectionConfidence = row.confidence
		finding.modelId = row.modelId
		finding.creationDate_ = row.creationDate ?? .now
		finding.boxX = row.box.x
		finding.boxY = row.box.y
		finding.boxWidth = row.box.width
		finding.boxHeight = row.box.height
		finding.screenshotFilename = screenshotFilename

		// The archived timestamp is authoritative: stamping "now" would make a restored copy win
		// last-write-wins against a newer edit elsewhere. v0 archives carry none, so fall back the
		// way the attribute documents.
		finding.preservesModifiedAt = true
		finding.modifiedAt = row.modifiedAt ?? row.creationDate ?? .now

		let target = row.lifeCycle.flatMap(CoreDataManageableState.init(rawValue:)) ?? .ready
		switch target {
		case .ready, .undefined:
			finding.transition(to: .draft)
			try finding.throwIfInvalid()
			finding.transition(to: .ready)
		case .draft:
			finding.transition(to: .draft)
			try finding.throwIfInvalid()
		case .deprecated, .empty:
			finding.transition(to: target)
		}
	}

	/// Puts a replaced image back, or removes the replacement when there was nothing there before.
	private func restore(_ backup: (filename: String, data: Data?)?) {
		guard let backup else { return }
		guard let data = backup.data else {
			FindingScreenshotStore.delete(filename: backup.filename)
			return
		}
		guard let url = FindingScreenshotStore.url(forFilename: backup.filename) else { return }
		do {
			try data.write(to: url, options: .atomic)
		} catch {
			LoggingPolicy.warning("Could not restore a replaced finding image", logger: .storage)
		}
	}

	/// Removes every finding (AIA-0303, Settings → Reset → Remove Findings). Batch-deletes all
	/// `Finding` rows on a background context, merging the deletion into the live `viewContext` so
	/// an open `@FetchRequest` refreshes and no zombie rows can resurrect on a later save; then, and
	/// only if the row delete succeeded, sweeps the now-orphaned screenshot files.
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

	/// The title this device already stores for `entityId`, or `nil` when it stores no such finding.
	///
	/// **Read-only, and the only reason a shared link touches Core Data at all (AIA-0650).** A link
	/// whose id matches a local row is the recipient's *own* finding — most often the sender opening
	/// their own link — and showing them a stranger's-eye, "unverified" card of their own work would
	/// be nonsense. The title is read back from the store rather than taken from the link so the one
	/// piece of text that screen renders is the verified local copy, not the attacker-controllable
	/// one in the URL fragment. Nothing here writes: a shared link never creates a `Finding`.
	func storedFindingTitle(_ entityId: UUID) -> String? {
		Finding.select(entityId, in: context)?.displayTitle
	}

	/// Trim, then treat an all-whitespace field as absent (nil) — matches the former view helper.
	private static func normalized(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}
}
