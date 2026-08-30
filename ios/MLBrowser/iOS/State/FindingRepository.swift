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
/// local `Documents/Findings` (via `FindingScreenshotStore`). This type is the only production
/// caller of `FindingScreenshotStore.save` — enforced by
/// `ArchitectureTests.testOnlyFindingRepositoryWritesScreenshots`.
///
/// The invariant is about the *writer*, not about egress, and this comment used to claim both. A
/// screenshot now leaves the device by two paths: explicit user export (`FindingExporter`), and
/// cloud back-up for a signed-in account (`FindingsSyncCoordinator.upload`, AIA-713) — which is
/// gated on the account owning the finding, and readable in the privacy policy §3.5. Saying
/// "never transmitted off-device" here outlived the feature that made it false, which is exactly
/// how a future reader ends up trusting it.
@MainActor
final class FindingRepository {

	/// Called with a finding's id immediately BEFORE a user-initiated delete commits, so sync can
	/// record the tombstone first. Wired by `DependencyContainer`; `nil` leaves deletes purely
	/// local, which is exactly what a build with no sync should do.
	/// Throws to STOP the delete. A tombstone that could not be recorded means the cloud copy would
	/// survive on every other device while the user was told the finding was gone.
	var willDeleteFinding: ((UUID) throws -> Void)?

	/// Called with a finding's id right after it is created here, so sync can record that this
	/// account made it — which is what separates the user's own work from whatever else happens to
	/// be in a shared device's store.
	var didCreateFinding: ((UUID) -> Void)?

	/// Called with every finding's id before a wholesale removal commits. Throws to stop it, for
	/// the same reason ``willDeleteFinding`` does.
	var willDeleteAllFindings: (([UUID]) throws -> Void)?

	/// Called after findings change locally, so sync can offer them to the cloud without waiting for
	/// the app to be backgrounded and reopened. `nil` in a build with no sync.
	var didChangeFindings: (() -> Void)?

	private let dataController: DataController

	init(dataController: DataController) {
		self.dataController = dataController
	}

	private var context: NSManagedObjectContext {
		dataController.container.viewContext
	}

	/// Commits edits the caller has already made to a stored finding.
	///
	/// The caller owns the field mapping -- an edit screen knows which fields it exposes and this
	/// type should not -- so this is only the commit and the notification. It exists because the
	/// notification was the part that kept getting missed: create, import and delete all ring
	/// ``didChangeFindings``, and the edit screen called `Finding.save(in:)` directly, which
	/// persisted the change and told sync nothing. An edited finding was still *marked* as owed
	/// (`willSave()` stamps `modifiedAt` on that path too), so it did upload -- whenever some
	/// unrelated trigger happened to fire next. Uploading a correction at an arbitrary later time is
	/// its own kind of wrong (AIA-737).
	func commitEdits() throws {
		try Finding.save(in: context)
		didChangeFindings?()
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
		// The **observation's** confidence, which is what the annotation draws and what the
		// confidence threshold filters on (AIA-0765). It used to prefer the first label's
		// confidence, and that is the class probability: on a single-class detector it is
		// trivially 1.0, so every saved finding recorded a perfect score regardless of how weak
		// the detection actually was.
		finding.detectionConfidence = Double(capture.observation.confidence)
		finding.modelId = capture.params?.entityId
		finding.boxX = box.minX
		finding.boxY = box.minY
		finding.boxWidth = box.width
		finding.boxHeight = box.height
		// The capture-space box is derived HERE rather than passed in (AIA-0761). `box` is the
		// caller's — the save sheet's — box, already re-normalized into the crop it baked into
		// `image`; the detection's position on the captured view is `capture`'s to state, and
		// `capture` is already a parameter. A second box argument would be one more thing a future
		// caller could forget to pass correctly, which is precisely the failure this fixes.
		let captureBox = capture.observation.boundingBox
		finding.captureBoxX = captureBox.minX
		finding.captureBoxY = captureBox.minY
		finding.captureBoxWidth = captureBox.width
		finding.captureBoxHeight = captureBox.height

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

		didCreateFinding?(entityId)
		didChangeFindings?()
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
		/// The device could not store the row — no disk space, a store error. Trying again may work.
		var failed = 0
		/// The row itself is not a valid finding, so trying again reproduces it exactly. Kept apart
		/// from `failed` because a caller that retries the whole page — sync does — would otherwise
		/// pin itself on one bad row for ever and lose every finding behind it.
		var rejected = 0

		mutating func count(_ error: Error) {
			if error is ImportRejection { rejected += 1 } else { failed += 1 }
		}
	}

	/// A row that will never import, however many times it is tried.
	enum ImportRejection: Error {
		case invalidContent
	}

	/// Which of the two counters a per-row failure belongs in.
	///
	/// The distinction is not cosmetic: sync retries a page, so a row whose own content is invalid
	/// would pin the cursor on itself for ever and lose every finding behind it, while a row the
	/// device merely could not write must be retried once there is room.

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
		var replacedImages: [(filename: String, data: Data?)] = []
		var writtenFilenames: [String] = []
		// Which rows this import created and which it replaced, so a failed commit can be undone in
		// the PARENT context too. `importContext.reset()` only abandons the child: by then the child
		// save has already pushed every row into the parent, where they sit pending and get written
		// by the next unrelated save -- as findings the user was told had failed to import, with
		// their images already deleted.
		var createdIds: [UUID] = []
		var replacedIds: [UUID] = []

		// All import work happens in a CHILD context, never directly in the viewContext.
		//
		// The reason is `rollback()`. Discarding a failed import used to mean rolling back the app's
		// shared context, which would also throw away any unrelated edit the user happened to have
		// pending — and, symmetrically, a successful import would commit those unrelated edits as a
		// side effect. A child context makes the import's own changes the only thing that can be
		// discarded: on failure the child is simply abandoned, and the parent never saw it.
		let importContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
		importContext.parent = context

		// Objects whose `modifiedAt` suppression must be lifted once the save that consumes it is
		// done. Leaving the flag set would freeze the timestamp of every imported finding FOR EVER:
		// the managed object stays live, and every later edit would keep the archived value.
		var suppressed: [Finding] = []
		defer { for finding in suppressed { finding.preservesModifiedAt = false } }

		for row in contents.rows {
			let existing = Finding.select(row.id, in: importContext)
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

				let finding = existing ?? Finding.create(in: importContext)
				suppressed.append(finding)
				try apply(row, to: finding, screenshotFilename: filename)
				if existing == nil { createdIds.append(row.id) } else { replacedIds.append(row.id) }
				summary.restored += 1
			} catch {
				LoggingPolicy.warning(
					"Skipped a finding during import: \(error.localizedDescription)",
					logger: .storage
				)
				restore(backup)
				if let existing {
					// Never delete a finding the user already had because an archived copy was bad.
					importContext.refresh(existing, mergeChanges: false)
				} else if let pending = Finding.select(row.id, in: importContext) {
					importContext.delete(pending)
				}
				if let filename, backup == nil, existing == nil {
					FindingScreenshotStore.delete(filename: filename)
					writtenFilenames.removeAll { $0 == filename }
				}
				summary.count(error)
			}
		}

		var reachedParent = false
		do {
			// Child first (validates and pushes into the parent), then the parent to the store.
			try importContext.save()
			reachedParent = true
			try preservingTimestamps(of: createdIds + replacedIds) { try Finding.save(in: context) }
		} catch {
			// Undo this import's own rows in the parent, by id, and nothing else -- the parent's
			// unrelated pending edits are deliberately left alone. Only when the child save
			// actually pushed them: if it was the one that threw, the parent never saw them, and
			// refreshing a pre-existing finding here would discard edits that are not ours.
			if reachedParent { undoInParent(created: createdIds, replaced: replacedIds) }
			importContext.reset()
			for filename in writtenFilenames {
				FindingScreenshotStore.delete(filename: filename)
			}
			for backup in replacedImages {
				restore(backup)
			}
			LoggingPolicy.error("Finding import failed to commit", error: error, logger: .storage)
			throw error
		}

		didChangeFindings?()
		return summary
	}

	/// Runs `work` with `preservesModifiedAt` set on the PARENT's instances of the given rows.
	///
	/// The flag was set on the child's instances; the parent holds its own instances of the same
	/// rows, with the flag false. Its `willSave()` would then restamp "now" over an archived
	/// timestamp whenever the assignment did not reach `changedValues()` — a replace whose stored
	/// value already equals the archived one — handing the restored copy a false win over the edit
	/// it was meant to lose to.
	private func preservingTimestamps<T>(of ids: [UUID], _ work: () throws -> T) rethrows -> T {
		let rows = ids.compactMap { Finding.select($0, in: context) }
		for row in rows { row.preservesModifiedAt = true }
		defer { for row in rows { row.preservesModifiedAt = false } }
		return try work()
	}

	/// Takes one import's rows back out of the parent context, by id and nothing else.
	///
	/// `importContext.reset()` abandons the child, but by then the child's save has pushed every row
	/// into the parent, where they sit pending until some unrelated save writes them -- as findings
	/// the user was told had failed to import, whose images this method's caller has already
	/// deleted. The parent's own unrelated pending edits are deliberately left alone.
	private func undoInParent(created: [UUID], replaced: [UUID]) {
		for id in created {
			if let row = Finding.select(id, in: context) { context.delete(row) }
		}
		for id in replaced {
			if let row = Finding.select(id, in: context) { context.refresh(row, mergeChanges: false) }
		}
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
		// Nil means the archive did not STATE a capture box, not that there is none, so the local
		// value stands (AIA-0761) — the same nil-means-fallback rule `modifiedAt` and `lifeCycle`
		// use just below. This matters because cloud sync replace-imports automatically: writing
		// zeroes on nil would let a single un-updated peer strip the capture box off every device,
		// permanently, with nobody touching anything.
		if let captureBox = row.captureBox {
			finding.captureBoxX = captureBox.x
			finding.captureBoxY = captureBox.y
			finding.captureBoxWidth = captureBox.width
			finding.captureBoxHeight = captureBox.height
		}
		finding.screenshotFilename = screenshotFilename

		// The archived timestamp is authoritative: stamping "now" would make a restored copy win
		// last-write-wins against a newer edit elsewhere. v0 archives carry none, so fall back the
		// way the attribute documents.
		finding.preservesModifiedAt = true
		finding.modifiedAt = row.modifiedAt ?? row.creationDate ?? .now

		// Walk to `.draft` first, validate there, then step to the archived state.
		//
		// `transition(to:)` silently keeps the current state when a hop is not allowed, so applying
		// the archived lifecycle directly would leave a replaced `.ready` finding `.ready` even
		// though the archive says `.draft` — a wrong answer that looks like success. Every state can
		// reach `.draft`, and `.draft` can reach every state, so this is one deterministic route
		// rather than a per-pair table.
		let target = row.lifeCycle.flatMap(CoreDataManageableState.init(rawValue:)) ?? .ready
		Self.descendToDraft(finding)
		do {
			try finding.throwIfInvalid()
		} catch {
			// Typed rather than passed through, so a caller can tell "this row is wrong" from "this
			// device could not write it". Sniffing the NSError domain would be the alternative, and
			// a renamed domain would silently turn one into the other.
			LoggingPolicy.warning("An imported finding failed validation: \(error.localizedDescription)", logger: .storage)
			throw ImportRejection.invalidContent
		}
		if target != .draft {
			finding.transition(to: target)
		}
	}

	/// Moves a finding to `.draft` from wherever it is, using only permitted transitions.
	private static func descendToDraft(_ finding: Finding) {
		if finding.lifeCycle == .ready { finding.transition(to: .deprecated) }
		if finding.lifeCycle == .deprecated { finding.transition(to: .empty) }
		if finding.lifeCycle != .draft { finding.transition(to: .draft) }
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
		// Tombstones first, and for every finding: this action promises permanent deletion, and
		// without them the local rows would go while every cloud copy stayed, ready to come back on
		// the next sync. Recorded before the batch delete for the same reason a single delete is:
		// a crash in between must complete the deletion, not lose it.
		try willDeleteAllFindings?(Finding.selectAll(in: context).map(\.entityId))
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

	/// Deletes one finding at the user's request.
	///
	/// Lives here rather than in the list view because a delete now has to reach the cloud: the
	/// tombstone is recorded through ``willDeleteFinding`` **before** the delete commits, so a
	/// crash in between completes the delete on the next sync. The other order would lose it, and a
	/// finding the user deleted would come back from another device -- for this app that means site
	/// coordinates reappearing after someone chose to remove them.
	///
	/// Entity first (committed), then a best-effort file delete: a leftover file is exactly the
	/// direction the orphan sweep self-heals. The filename is captured before deletion, because
	/// Core Data nullifies attributes on delete.
	func delete(_ finding: Finding) throws {
		let entityId = finding.entityId
		let filename = finding.screenshotFilename
		try willDeleteFinding?(entityId)
		context.delete(finding)
		try Finding.save(in: context)
		FindingScreenshotStore.delete(filename: filename)
		didChangeFindings?()
	}

	/// Applies a delete that came FROM the cloud.
	///
	/// Deliberately does not call ``willDeleteFinding``: this device is being told about a delete,
	/// not making one, and echoing it back as a fresh tombstone would restamp it with a newer
	/// timestamp and let it win a conflict it had already lost.
	func deleteReceivedFromCloud(_ entityId: UUID) throws {
		guard let finding = Finding.select(entityId, in: context) else { return }
		let filename = finding.screenshotFilename
		context.delete(finding)
		try Finding.save(in: context)
		FindingScreenshotStore.delete(filename: filename)
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
