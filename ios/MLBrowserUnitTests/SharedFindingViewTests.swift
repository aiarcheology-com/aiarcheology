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
		locationText: String? = nil,
		box: FindingShareLink.Box? = nil,
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
			locationText: locationText,
			box: box,
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
		XCTAssertFalse(sections.contains(.location))
		XCTAssertEqual(sections, [.provenance, .title])
	}

	/// A location the app cannot plot still has to be *shown* (AIA-0836).
	///
	/// The reported bug: a finding captured on a Czech geoportal carries S-JTSK, which is projected
	/// metres and not degrees, so `coordinate` is nil and the block was dropped entirely. The sender's
	/// card showed a location and the recipient's showed none. The block appears, carrying the
	/// sender's own words; only the map beneath it needs degrees.
	func test_layout_withAnUnplottableLocation_stillShowsTheBlock() {
		let written = "S-JTSK (EPSG:5514): -831425.5856845, -1028149.4515314"
		let sections = SharedFindingSection.layout(for: payload(locationText: written))

		XCTAssertEqual(sections, [.provenance, .title, .location])
		XCTAssertEqual(SharedFindingSection.locationText(for: payload(locationText: written)), written)
	}

	/// And the sender's wording wins over the reformatted degrees when both travelled, so the two
	/// cards read the same.
	func test_theLocationRowPrefersTheSendersWording() {
		let both = payload(
			coordinate: FindingShareLink.Coordinate(latitude: 47.94123, longitude: 18.709545),
			locationText: "leaflet: 47.94123, 18.709545"
		)
		XCTAssertEqual(SharedFindingSection.locationText(for: both), "leaflet: 47.94123, 18.709545")
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
		XCTAssertEqual(sections, [.provenance, .title, .location])
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
		XCTAssertEqual(sections, [.provenance, .title, .openPage, .detection, .author, .date, .page, .location])
	}

	/// The open-page block sits directly after the title, and exists only when a page travelled.
	///
	/// Pinned because the position is the security posture, not a layout preference (AIA-0659): the
	/// block carries the button that leaves the app **and** the full address it will open, so a link
	/// that moved the two apart — or promoted the button on a payload with no page — would be
	/// offering a stranger's action without the disclosure that makes it judgeable.
	func test_layout_placesTheOpenPageBlockUnderTheTitle_onlyWhenAPageTravelled() {
		let withPage = SharedFindingSection.layout(
			for: payload(page: URL(string: "https://example.org/ridge"))
		)
		XCTAssertEqual(withPage, [.provenance, .title, .openPage, .page])

		let withoutPage = SharedFindingSection.layout(for: payload())
		XCTAssertFalse(withoutPage.contains(.openPage))
		XCTAssertEqual(withoutPage, [.provenance, .title])
	}

	// MARK: - Where on the page (AIA-0657)

	/// The box block sits immediately after the page, because it qualifies it: for a detection that
	/// is not on a map, the page plus the place on it is the entire locator.
	func test_layout_placesTheBoxDirectlyAfterThePage() throws {
		let sections = SharedFindingSection.layout(
			for: payload(
				box: try XCTUnwrap(FindingShareLink.Box(x: 0.1, y: 0.2, width: 0.3, height: 0.4)),
				page: URL(string: "https://example.org/ridge")
			)
		)
		XCTAssertEqual(sections, [.provenance, .title, .openPage, .page, .box])
	}

	/// A box with no page still locates something — "somewhere on the page it came from" is weaker
	/// than a page plus a box, but it is not nothing, and dropping it would lose the only locator a
	/// link whose address was reduced still has.
	func test_layout_keepsTheBoxWithoutAPage() throws {
		let sections = SharedFindingSection.layout(
			for: payload(box: try XCTUnwrap(FindingShareLink.Box(x: 0.1, y: 0.2, width: 0.3, height: 0.4)))
		)
		XCTAssertEqual(sections, [.provenance, .title, .box])
	}

	func test_layout_omitsTheBoxWhenTheLinkCarriesNone() {
		XCTAssertFalse(SharedFindingSection.layout(for: payload()).contains(.box))
	}

	/// The two claims the screen is allowed to make about the box, and the two the wire format can
	/// actually support: where it sits, and how much of the page it covers. The captured view's
	/// aspect ratio does not travel, so the drawn shape is indicative and nothing asserts otherwise.
	func test_boxAreaAndPositionAreExactEvenThoughTheShapeIsNot() throws {
		let box = try XCTUnwrap(FindingShareLink.Box(x: 0.25, y: 0.5, width: 0.2, height: 0.1))
		XCTAssertEqual(box.areaFraction, 0.02, accuracy: 1e-9)
		XCTAssertEqual(box.x, 0.25, accuracy: 1e-9)
		XCTAssertEqual(box.y, 0.5, accuracy: 1e-9)
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
			return FindingRepository.StoredFindingSummary(title: "Rampart", source: .local)
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
			return FindingRepository.StoredFindingSummary(title: "My own rampart", source: .local)
		}
		XCTAssertEqual(presentation, .owned(localTitle: "My own rampart"))
		XCTAssertEqual(lookedUp, identifier)
	}

	/// The owned screen must show the store's title, not the link's. A forged link carrying the
	/// recipient's own id with someone else's title must not put that title on the one screen that
	/// shows no provenance warning.
	///
	/// The previous version of this test compared `.owned("Stored title")` against
	/// `.owned("Forged title")` — two unequal literals — so it passed no matter what `resolve` did.
	/// What actually needs proving is that **nothing about the link except its id can change the
	/// result**, so this drives two payloads that differ in every field but `id` and requires the
	/// same presentation out of both.
	func test_resolve_ignoresEverythingInTheLinkExceptItsID() {
		let identifier = UUID()
		let honest = payload(id: identifier, title: "My own rampart")
		let forged = FindingShareLink.Payload(
			id: identifier,
			title: "Forged title",
			detectionClass: "forged",
			confidencePercent: 1,
			coordinate: FindingShareLink.Coordinate(latitude: 1, longitude: 1),
			page: URL(string: "https://attacker.example/x"),
			author: "Someone Else",
			date: DateComponents(year: 2000, month: 1, day: 1)
		)

		let fromHonest = SharedFindingPresentation.resolve(payloadId: honest.id) { _ in
			FindingRepository.StoredFindingSummary(title: "Stored title", source: .local)
		}
		let fromForged = SharedFindingPresentation.resolve(payloadId: forged.id) { _ in
			FindingRepository.StoredFindingSummary(title: "Stored title", source: .local)
		}

		XCTAssertEqual(fromHonest, .owned(localTitle: "Stored title"))
		XCTAssertEqual(fromForged, fromHonest, "no link field but the id may reach the owned screen")
	}

	/// A link whose id this device does not know must never resolve to `owned`, whatever else it
	/// carries — otherwise a stranger's link could reach the screen that shows no warning.
	func test_resolve_withoutAStoredMatchStaysUnverified() {
		XCTAssertEqual(SharedFindingPresentation.resolve(payloadId: UUID()) { _ in nil }, .unverified)
		XCTAssertEqual(
			SharedFindingPresentation.resolve(payloadId: nil) { _ in
				FindingRepository.StoredFindingSummary(title: "Stored title", source: .local)
			},
			.unverified
		)
	}
}

// MARK: - AIA-0835: a stored row is not necessarily the user's own

@MainActor
final class SharedFindingReceivedResolutionTests: XCTestCase {

	/// The regression this exists for: `saveReceived` stores the link's finding, so on every open
	/// after the first the id matches. A source-blind resolver answers `.owned` there and the screen
	/// tells the user a stranger's find is theirs.
	///
	/// Mutate the harmful direction: collapse `resolve`'s switch to always return `.owned` and this
	/// goes red while the `.local` cases stay green.
	func test_resolve_withAnIdStoredAsReceived_isAlreadyReceivedNotOwned() {
		let presentation = SharedFindingPresentation.resolve(payloadId: UUID()) { _ in
			FindingRepository.StoredFindingSummary(title: "Someone else's rampart", source: .received)
		}

		XCTAssertEqual(presentation, .alreadyReceived(localTitle: "Someone else's rampart"))
	}

	/// The same lookup result differing ONLY by source must produce different screens — otherwise
	/// the distinction is decorative.
	func test_resolve_sameTitleDifferentSource_resolvesDifferently() {
		let identifier = UUID()
		let asLocal = SharedFindingPresentation.resolve(payloadId: identifier) { _ in
			FindingRepository.StoredFindingSummary(title: "Same title", source: .local)
		}
		let asReceived = SharedFindingPresentation.resolve(payloadId: identifier) { _ in
			FindingRepository.StoredFindingSummary(title: "Same title", source: .received)
		}

		XCTAssertEqual(asLocal, .owned(localTitle: "Same title"))
		XCTAssertEqual(asReceived, .alreadyReceived(localTitle: "Same title"))
		XCTAssertNotEqual(asLocal, asReceived)
	}
}

// MARK: - AIA-0835: the link state machine

/// `SharedFindingState` gained the import, and with it the state that decides whether the editor is
/// on screen. None of it was covered — which is how re-delivering the same link came to tear the
/// editor down with nothing able to restore it.
@MainActor
final class SharedFindingImportStateTests: XCTestCase {

	private var dataController: DataController!
	private var repository: FindingRepository!
	private var sut: SharedFindingState!

	override func setUp() async throws {
		try await super.setUp()
		dataController = DataController(inMemory: true)
		await dataController.awaitStoreReady()
		repository = FindingRepository(dataController: dataController)
		sut = SharedFindingState()
	}

	override func tearDown() async throws {
		sut = nil
		repository = nil
		dataController = nil
		try await super.tearDown()
	}

	private func link(title: String = "Rampart", id: UUID = UUID()) throws -> URL {
		try XCTUnwrap(FindingShareLink.url(for: FindingShareLink.Payload(id: id, title: title)))
	}

	func test_storePendingFinding_storesTheLinksFinding() throws {
		sut.handle(try link())
		sut.storePendingFinding(using: repository)

		XCTAssertNotNil(sut.storedId)
		XCTAssertFalse(sut.importFailed)
	}

	/// The overlay can re-appear — backgrounding, a size-class change — and each `onAppear` calls
	/// this. A second write would duplicate an id-less link.
	func test_storePendingFinding_twiceForOneLink_storesOnce() throws {
		sut.handle(try link())
		sut.storePendingFinding(using: repository)
		let first = sut.storedId
		sut.storePendingFinding(using: repository)

		XCTAssertEqual(sut.storedId, first)
		XCTAssertEqual(try dataController.container.viewContext.count(for: Finding.fetchRequest()), 1)
	}

	/// The D5 regression: the same link arriving again must leave the editor exactly where it is.
	/// Clearing `storedId` here stranded it — `pending` stayed equal so nothing re-resolved, and the
	/// re-store was refused as a duplicate.
	func test_handle_withTheSameLinkAgain_keepsTheStoredFindingOnScreen() throws {
		let url = try link()
		sut.handle(url)
		sut.storePendingFinding(using: repository)
		let stored = sut.storedId
		XCTAssertNotNil(stored)

		sut.handle(url)

		XCTAssertEqual(sut.storedId, stored, "re-tapping a link must not tear down what it already opened")
	}

	/// A different link must not inherit the previous one's row.
	func test_handle_withADifferentLink_clearsThePreviousResolution() throws {
		sut.handle(try link(title: "First"))
		sut.storePendingFinding(using: repository)
		XCTAssertNotNil(sut.storedId)

		sut.handle(try link(title: "Second"))

		XCTAssertNil(sut.storedId)
	}

	/// An unreadable link used to keep the previous link's `storedId`, so the host — which prefers a
	/// stored finding — reopened the old finding instead of saying the link could not be read.
	func test_handle_withAnUnreadableLink_clearsThePreviousResolution() throws {
		sut.handle(try link())
		sut.storePendingFinding(using: repository)
		XCTAssertNotNil(sut.storedId)

		sut.handle(try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=")))

		XCTAssertEqual(sut.pending, .unreadable)
		XCTAssertNil(sut.storedId, "an unreadable link must not reopen the last finding")
	}

	func test_dismiss_clearsEverything() throws {
		sut.handle(try link())
		sut.storePendingFinding(using: repository)

		sut.dismiss()

		XCTAssertNil(sut.pending)
		XCTAssertNil(sut.storedId)
	}
}
