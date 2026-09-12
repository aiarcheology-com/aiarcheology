//
//  FindingSource.swift
//  AI Archeology
//
//  Where a finding came from — the one bit that separates the My and Received tabs (AIA-0835).
//

import Foundation

/// Where a finding came from.
///
/// One behavioural dimension, modelled once: it decides which tab a finding lists under, whether
/// its fields are editable, and whether the row is the user's own work or somebody else's. The tabs
/// **are** the sources — there is deliberately no parallel `enum Tab`, which would be a second name
/// for one distinction.
///
/// Stored as a string in `Finding.source_` and read through ``Finding/source``, never branched on by
/// runtime symbol name: the `rawValue` is an explicit, stable tag that survives release builds,
/// minification and symbol stripping.
enum FindingSource: String, CaseIterable, Sendable {
	/// Captured on this device. Every row written before AIA-0835 is this, and so is every row whose
	/// provenance was never recorded — see ``Finding/source``.
	case local

	/// Imported from a share link somebody else sent.
	///
	/// Read-only: the stored copy has to keep matching what the sender sent, which is what makes the
	/// finding id a signature rather than a local identifier. Sharing such a finding onward is still
	/// allowed — forwarding is not editing, and `FindingShareCard` reads `author` straight off the
	/// row, so the sender keeps the credit.
	///
	/// **Deleting one is allowed too, and that is not a hole in the rule.** Read-only constrains what
	/// a field may say, not whether the row exists: a received finding the user does not want is
	/// theirs to be rid of, which is the whole point of the Received tab having a delete at all. The
	/// rule the editor enforces is that no *stored value* may drift from what arrived — an edited
	/// copy would still carry the sender's id while no longer being what they sent.
	case received
}

extension Finding {
	/// This finding's provenance, with a fail-safe reading of anything unexpected.
	///
	/// ## Nil and "unrecognised" are different claims
	/// A **nil** `source_` means nothing was ever recorded — the row predates the attribute, or came
	/// from an archive written before it existed — and such a row is the user's own, so it reads as
	/// ``FindingSource/local``.
	///
	/// An **unrecognised non-nil** value means the opposite: something that *understood* provenance
	/// wrote a value this build cannot parse. Reading that as `.local` would be a privilege
	/// fallback — it would make content of unknown origin editable and presented as the user's own
	/// work. It therefore reads as ``FindingSource/received``, which fails safe: read-only, and still
	/// visible in a tab rather than vanishing from both.
	var source: FindingSource {
		get {
			guard let raw = source_ else { return .local }
			return FindingSource(rawValue: raw) ?? .received
		}
		set { source_ = newValue.rawValue }
	}
}
