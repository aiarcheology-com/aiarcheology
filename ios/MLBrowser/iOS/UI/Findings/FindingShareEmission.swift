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
	/// - Parameter pageDetail: how much of the captured address the sender chose to send. Defaults
	///   to ``FindingShareLink/PageDetail/siteOnly`` so a caller that says nothing emits the
	///   narrower link — the sender's choice has to be spoken aloud to widen it.
	func linkPayload(pageDetail: FindingShareLink.PageDetail = .siteOnly) -> FindingShareLink.Payload {
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
			// Where on the captured view the detection sat. For a detection on an ordinary page — a
			// cat, a car, anything the model finds on a page that is not a map — this is the
			// locator, in a way a coordinate never is: `gps_` is hand-typed and usually empty, while
			// every finding has a box.
			//
			// **`captureNormalizedBox`, never `normalizedBox`** (AIA-0761). The two are the same
			// rectangle only until the save sheet bakes a crop in; after that `normalizedBox` is
			// crop-relative, and since AIA-0757 opened the editor pre-framed on the detection, that
			// is essentially every finding. Every *visual* consumer is right to read `normalizedBox`
			// — each pairs it with the stored image. The link is the one consumer that pairs the box
			// with something else, the captured view, and the recipient has no crop to reconcile it
			// against. `FindingShareEmissionTests` pins this.
			//
			// `.zero` is what a row carries when the capture box was never recorded — saved before
			// the attribute existed, or imported from an older client — and `Box` refuses a
			// zero-area rect, so those links simply carry no box (AIA-0657). Omitting it is the
			// point: the crop discarded the original, so there is nothing honest left to send.
			box: FindingShareLink.Box(
				x: captureNormalizedBox.minX,
				// Vision's origin is bottom-left; the wire's is top-left. Converted here, at the one
				// boundary where a browsed finding enters the share contract, so no other caller has
				// to remember which way up the format is.
				y: 1 - captureNormalizedBox.maxY,
				width: captureNormalizedBox.width,
				height: captureNormalizedBox.height
			),
			// Reduced *here*, at the one point a raw browsed URL — session tokens and all — enters the
			// share contract. `FindingShareLink.assemble` reduces again on the way out, so the safety
			// does not depend on this call being remembered; doing it here as well means the `Payload`
			// a caller can inspect already matches what would travel, which is what lets the composer
			// show the sender the real address.
			page: page.flatMap { FindingShareLink.sanitizedPage($0.absoluteString, detail: pageDetail) },
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
		// Clamped as a `Double`, BEFORE the conversion — not after. `Int(_:)` traps on a value outside
		// `Int`'s range, so the old `min(100, max(0, Int(x * 100)))` crashed on exactly the input the
		// clamp was written to defend against: the conversion ran first and took the process with it.
		// `Finding.detectionConfidence` is an unconstrained Core Data `Double`, so a corrupt or
		// imported row is enough to reach this, and sharing that finding would have killed the app.
		return Int((min(1, max(0, confidence)) * 100).rounded())
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
		includesLink: Bool,
		pageDetail: FindingShareLink.PageDetail = .siteOnly
	) -> [Any] {
		guard isLinkEnabled, includesLink,
		      let link = FindingShareLink.url(for: subject.linkPayload(pageDetail: pageDetail), pageDetail: pageDetail)
		else { return [image] }
		return [image, link.absoluteString]
	}
}
