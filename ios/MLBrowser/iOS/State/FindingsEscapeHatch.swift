//
//  FindingsEscapeHatch.swift
//  AI Archeology
//
//  The shared "take your findings with you" export step (AIA-0303/0402/0556).
//

import Foundation

/// The export half of every "your findings are about to become unreachable" offer: the paywall dead
/// end (AIA-0556) and Settings → Reset → Remove Findings (AIA-0303) both build the same archive, and
/// both must wait out the same dismissal animation before anything can be presented.
///
/// MainActor-isolated because the snapshot read goes through `FindingRepository`'s viewContext; the
/// expensive part is explicitly handed off the actor. Callers keep what actually differs between the
/// two screens: their own in-progress flag, their own logging, their own error surface, and their own
/// presenter.
@MainActor
enum FindingsEscapeHatch {
	/// Snapshots every stored finding, builds the export ZIP off the MainActor, and returns its URL
	/// only once the confirmation dialog that triggered the export has had time to finish dismissing.
	///
	/// The wait is the reason this is not just `FindingExporter.makeZip`: a fast export (a single
	/// finding) finishes while the dialog is still going down, and presenting into a presenter that is
	/// mid-dismissal is a silent no-op that drops the share sheet entirely (AIA-0402). Returning late
	/// keeps that delay in one place instead of relying on each caller to remember it.
	static func makeShareableZip(from repository: FindingRepository) async throws -> URL {
		let snapshots = repository.allFindingSnapshots()
		let url = try await Task.detached(priority: .userInitiated) {
			try FindingExporter.makeZip(from: snapshots)
		}.value
		try? await Task.sleep(for: .milliseconds(500))
		return url
	}
}
