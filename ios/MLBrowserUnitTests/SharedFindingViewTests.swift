//
//  SharedFindingViewTests.swift
//  MLBrowserUnitTests
//
//  The layout and ownership decisions behind the shared-finding screen (AIA-0650).
//

import XCTest
@testable import ML_Browser

/// Covers the two pure decisions the read-only shared-finding screen is built on: which of its two
/// screens a link resolves to, and which blocks the unverified card contains.
///
/// Both are exercised through the same functions the view itself calls — `layout(for:)` *is* the
/// body's data source, not a description of it — so a passing test here is evidence about the
/// rendered screen rather than about a parallel copy of its rules.
final class SharedFindingViewTests: XCTestCase {

	private func payload(
		id: UUID? = nil,
		title: String = "Rampart",
		detectionClass: String? = nil,
		confidencePercent: Int? = nil,
		coordinate: FindingShareLink.Coordinate? = nil,
		page: URL? = nil,
		author: String? = nil,
		date: DateComponents? = nil
	) -> FindingShareLink.Payload {
		FindingShareLink.Payload(
			id: id,
			title: title,
			detectionClass: detectionClass,
			confidencePercent: confidencePercent,
			coordinate: coordinate,
			page: page,
			author: author,
			date: date
		)
	}

	// MARK: - The primary layout: no coordinate

	/// The case that happens most: `Finding.gps_` is free text nothing auto-populates, so the link
	/// usually carries no coordinate. There must be no map block at all — not an empty one.
	func test_layout_withoutACoordinate_omitsTheMapEntirely() {
		let sections = SharedFindingSection.layout(for: payload())
		XCTAssertFalse(sections.contains(.map))
		XCTAssertEqual(sections, [.provenance, .title])
	}

	/// A bare link — title only — still renders the warning and the title, and nothing else. This is
	/// what guards against a screen of empty rows for the minimum payload the parser accepts.
	func test_layout_minimalPayload_isProvenanceAndTitleOnly() {
		XCTAssertEqual(SharedFindingSection.layout(for: payload()), [.provenance, .title])
	}

	/// Provenance is not optional and not last. Every other block renders attacker-supplied text, so
	/// the sentence that says as much has to be the first thing on screen.
	func test_layout_alwaysLeadsWithProvenance() {
		let full = payload(
			id: UUID(),
			detectionClass: "earthwork",
			confidencePercent: 82,
			coordinate: FindingShareLink.Coordinate(latitude: 48.8, longitude: 19.53),
			page: URL(string: "https://example.org/ridge"),
			author: "M. Novák",
			date: DateComponents(year: 2026, month: 5, day: 14)
		)
		XCTAssertEqual(SharedFindingSection.layout(for: full).first, .provenance)
		XCTAssertEqual(SharedFindingSection.layout(for: payload()).first, .provenance)
	}

	// MARK: - The special case: a coordinate

	func test_layout_withACoordinate_appendsTheMap() {
		let sections = SharedFindingSection.layout(
			for: payload(coordinate: FindingShareLink.Coordinate(latitude: 48.8, longitude: 19.53))
		)
		XCTAssertEqual(sections, [.provenance, .title, .map])
	}

	func test_layout_includesEveryBlockThePayloadCarries() {
		let sections = SharedFindingSection.layout(
			for: payload(
				detectionClass: "earthwork",
				confidencePercent: 82,
				coordinate: FindingShareLink.Coordinate(latitude: 48.8, longitude: 19.53),
				page: URL(string: "https://example.org/ridge"),
				author: "M. Novák",
				date: DateComponents(year: 2026, month: 5, day: 14)
			)
		)
		XCTAssertEqual(sections, [.provenance, .title, .detection, .author, .date, .page, .map])
	}

	// MARK: - Optional blocks appear only when their content does

	func test_layout_omitsTheAuthorPageAndDateWhenAbsent() {
		let sections = SharedFindingSection.layout(for: payload(detectionClass: "ditch"))
		XCTAssertFalse(sections.contains(.author))
		XCTAssertFalse(sections.contains(.page))
		XCTAssertFalse(sections.contains(.date))
		XCTAssertTrue(sections.contains(.detection))
	}

	/// The detection chip has two independently optional halves. Whether the block exists and what it
	/// says come from the same function, so a chip can never be reserved for text that is nil.
	func test_detectionText_rendersWhicheverHalfArrived() {
		XCTAssertEqual(SharedFindingSection.detectionText(for: payload(detectionClass: "ditch", confidencePercent: 61)), "ditch · 61%")
		XCTAssertEqual(SharedFindingSection.detectionText(for: payload(detectionClass: "ditch")), "ditch")
		XCTAssertEqual(SharedFindingSection.detectionText(for: payload(confidencePercent: 61)), "61%")
		XCTAssertNil(SharedFindingSection.detectionText(for: payload()))
	}

	func test_layout_omitsTheDetectionBlockWhenNeitherHalfArrived() {
		XCTAssertFalse(SharedFindingSection.layout(for: payload()).contains(.detection))
	}

	// MARK: - Dates

	func test_date_resolvesACompleteDayInUTC() throws {
		let resolved = try XCTUnwrap(
			SharedFindingSection.date(for: payload(date: DateComponents(year: 2026, month: 5, day: 14)))
		)
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
		let components = calendar.dateComponents([.year, .month, .day], from: resolved)
		XCTAssertEqual(components.year, 2026)
		XCTAssertEqual(components.month, 5)
		XCTAssertEqual(components.day, 14)
	}

	/// `Calendar.date(from:)` happily fills in what a partial `DateComponents` omits, which would
	/// render a year-only link as the 1st of January — a date nobody sent. The block is dropped.
	func test_date_rejectsAPartialDate() {
		XCTAssertNil(SharedFindingSection.date(for: payload(date: DateComponents(year: 2026))))
		XCTAssertNil(SharedFindingSection.date(for: payload(date: DateComponents(year: 2026, month: 5))))
		XCTAssertFalse(SharedFindingSection.layout(for: payload(date: DateComponents(year: 2026))).contains(.date))
	}

	func test_date_isAbsentWhenTheLinkCarriedNone() {
		XCTAssertNil(SharedFindingSection.date(for: payload()))
	}

	// MARK: - Coordinate text

	func test_coordinateText_keepsFiveDecimalsAndAPoint() throws {
		let coordinate = try XCTUnwrap(FindingShareLink.Coordinate(latitude: 48.8, longitude: -19.53))
		XCTAssertEqual(SharedFindingSection.coordinateText(coordinate), "48.80000, -19.53000")
	}

	// MARK: - Ownership

	func test_resolve_withNoIdInTheLink_isUnverified() {
		let presentation = SharedFindingPresentation.resolve(payloadId: nil) { _ in
			XCTFail("A link with no id must not be looked up at all")
			return "Rampart"
		}
		XCTAssertEqual(presentation, .unverified)
	}

	func test_resolve_withAnIdThisDeviceDoesNotHave_isUnverified() {
		XCTAssertEqual(SharedFindingPresentation.resolve(payloadId: UUID()) { _ in nil }, .unverified)
	}

	func test_resolve_withAnIdThisDeviceStores_isOwnedAndUsesTheLocalTitle() {
		let identifier = UUID()
		var lookedUp: UUID?
		let presentation = SharedFindingPresentation.resolve(payloadId: identifier) { entityId in
			lookedUp = entityId
			return "My own rampart"
		}
		XCTAssertEqual(presentation, .owned(localTitle: "My own rampart"))
		XCTAssertEqual(lookedUp, identifier)
	}

	/// The owned screen must show the store's title, not the link's. A forged link carrying the
	/// recipient's own id with someone else's title must not put that title on an unwarned screen.
	func test_resolve_prefersTheStoredTitleOverTheLinksOwn() {
		let identifier = UUID()
		let presentation = SharedFindingPresentation.resolve(payloadId: identifier) { _ in "Stored title" }
		XCTAssertEqual(presentation, .owned(localTitle: "Stored title"))
		XCTAssertNotEqual(presentation, .owned(localTitle: payload(id: identifier, title: "Forged title").title))
	}
}
