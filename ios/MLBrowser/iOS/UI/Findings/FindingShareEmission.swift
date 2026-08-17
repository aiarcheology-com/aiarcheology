//
//  FindingShareEmission.swift
//  AI Archeology
//
//  What the share composer emits (AIA-0650): a finding reduced to a link payload, and the items
//  handed to the system share sheet.
//

import UIKit

// MARK: - Subject → link payload

extension FindingShareSubject {

	/// The finding reduced to what a link can carry.
	///
	/// This lives in the UI layer rather than beside ``FindingShareLink`` deliberately.
	/// `FindingShareSubject` carries a `UIImage`, so putting the mapping in Services would drag
	/// UIKit into the one file whose entire value is that it imports nothing but Foundation and can
	/// therefore be round-tripped in a unit test with no host app behind it.
	var linkPayload: FindingShareLink.Payload {
		FindingShareLink.Payload(
			id: id,
			title: title,
			detectionClass: detectionClass,
			confidencePercent: Self.percent(confidence),
			// `gps` is a plain `TextField` that nothing in this app validates or auto-populates, so a
			// value that will not parse is the **common** case rather than the exceptional one. It
			// means the link carries no coordinate and the recipient sees no map block at all, which
			// is what `SharedFindingSection.layout(for:)` is built around.
			coordinate: gps.flatMap(CoordinateText.parse),
			// Reduced *here*, before a `Payload` exists. `FindingShareLink` builds the link from
			// `page` verbatim and only sanitizes on the way back in, so an unreduced URL would travel
			// inside the emitted link and be dropped by the recipient — after the query string had
			// already been posted. This is the single point at which a raw browsed URL, session
			// tokens and all, enters the share contract.
			page: page.flatMap { FindingShareLink.sanitizedPage($0.absoluteString) },
			author: author,
			date: Self.day(from: date)
		)
	}

	/// Whole percent, rounded.
	///
	/// Clamped because `FindingShareLink.Payload` validates nothing on construction — only the
	/// parser does — so an out-of-range value would be emitted happily and then silently dropped
	/// when the link was read back, producing a link this app cannot itself fully parse.
	private static func percent(_ confidence: Double) -> Int? {
		guard confidence.isFinite else { return nil }
		return min(100, max(0, Int((confidence * 100).rounded())))
	}

	/// Day precision, on an explicit Gregorian/UTC calendar.
	///
	/// A finding's capture *time* is a movement record; the day alone is context. The calendar is
	/// pinned rather than taken from the device so a link written in one region resolves to the same
	/// day in another — the same calendar `FindingShareLink.parseDate` and `SharedFindingSection`
	/// use, so the three never disagree about which day a link names.
	private static func day(from date: Date?) -> DateComponents? {
		guard let date else { return nil }
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
		return calendar.dateComponents([.year, .month, .day], from: date)
	}
}

// MARK: - Share-sheet items

/// Builds the `UIActivityViewController` item list for a rendered share card.
///
/// Pulled out of the composer so the one decision that has user-visible consequences — whether a
/// link rides along, and in what form — is a pure function that a test can put both ways.
enum FindingShareActivity {

	/// The activity items for `image`, with the link attached only when the feature is on **and**
	/// the composer's toggle is on.
	///
	/// ## The link is a `String`, never a `URL`, and that is not a detail
	/// 1. A `URL` item makes `LinkPresentation` **fetch that URL from the sharer's device** to build
	///    the sheet's header card. That is a network request caused by an action the user believes
	///    is entirely local — they are sharing a picture they just composed — and this app's privacy
	///    posture (AGENTS §10) does not permit an outbound request nobody asked for.
	/// 2. A `URL` item also switches the sheet into link-preview presentation, which hides the image
	///    that is the actual subject of the share.
	///
	/// ## The cost, stated rather than hidden
	/// `UIActivityViewController` offers an activity only if it accepts **every** item, and
	/// `saveToCameraRoll` accepts only images and video file URLs. So with the link attached, Save
	/// Image and image-only share extensions drop out of the sheet. That is precisely what the
	/// composer's toggle exists to give back.
	///
	/// This is **not** fixable with a `UIActivityItemSource`. Eligibility is computed from
	/// `activityViewControllerPlaceholderItem`, whose *class alone* is consulted (see Apple's
	/// `UIActivityItemProvider.h`), and `itemForActivityType:` only runs after the user has already
	/// picked a destination — so any scheme where the placeholder's type differs from the real
	/// item's type is a lie told to the receiving extension, not a workaround.
	static func items(
		image: UIImage,
		subject: FindingShareSubject,
		isLinkEnabled: Bool,
		includesLink: Bool
	) -> [Any] {
		guard isLinkEnabled, includesLink,
		      let link = FindingShareLink.url(for: subject.linkPayload)
		else { return [image] }
		return [image, link.absoluteString]
	}
}
