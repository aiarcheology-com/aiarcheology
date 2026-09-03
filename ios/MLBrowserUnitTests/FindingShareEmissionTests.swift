//
//  FindingShareEmissionTests.swift
//  MLBrowserUnitTests
//
//  What the share composer emits (AIA-0650): the subject → payload mapping, the QR at the compact
//  cap, and the flag that decides whether a link leaves the app at all.
//

import UIKit
import Vision
import XCTest
@testable import ML_Browser

final class FindingShareEmissionTests: XCTestCase {

	// MARK: - Helpers

	private func makeSubject(
		id: UUID = UUID(),
		normalizedBox: CGRect = .zero,
		captureNormalizedBox: CGRect = .zero,
		title: String = "Roman wall",
		author: String? = "V. Slavík",
		gps: String? = "48.8, 19.53",
		detectionClass: String? = "stone_wall",
		confidence: Double = 0.87,
		date: Date? = nil,
		page: URL? = URL(string: "https://example.org/ruins")
	) -> FindingShareSubject {
		FindingShareSubject(
			id: id,
			normalizedBox: normalizedBox,
			captureNormalizedBox: captureNormalizedBox,
			title: title,
			author: author,
			gps: gps,
			detectionClass: detectionClass,
			confidence: confidence,
			date: date,
			page: page
		)
	}

	/// A small opaque bitmap standing in for the rendered card. Only its identity and its type
	/// matter to these tests.
	private func makeCardImage() -> UIImage {
		UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
			UIColor.darkGray.setFill()
			context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
		}
	}

	private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
		return try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
	}

	/// Decodes a QR bitmap the way a phone camera would — through Vision, not by re-deriving what we
	/// just encoded.
	///
	/// Every supported revision is tried, oldest first, and a revision that cannot *run* is skipped
	/// rather than counted as a failure to read: the newest barcode detector builds a Core ML
	/// inference context, which this simulator refuses to create ("Could not create inference
	/// context"). That is a property of the host, not of the symbol, and letting it fail the test
	/// would report a sizing bug that is not there.
	private func decodedQRPayload(of image: UIImage) throws -> String? {
		let cgImage = try XCTUnwrap(image.cgImage)
		let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
		var revisionsThatRan = 0

		for revision in VNDetectBarcodesRequest.supportedRevisions.sorted() {
			let request = VNDetectBarcodesRequest()
			request.revision = revision
			request.symbologies = [.qr]
			do {
				try handler.perform([request])
			} catch {
				continue
			}
			revisionsThatRan += 1
			if let payload = (request.results ?? []).compactMap(\.payloadStringValue).first {
				return payload
			}
		}

		XCTAssertGreaterThan(revisionsThatRan, 0, "No Vision barcode detector could run on this host")
		return nil
	}

	// MARK: - The QR, at the cap

	/// The test this file exists for.
	///
	/// A short payload always scans, so a happy-path fixture would pass while hiding the only failure
	/// mode that matters: a symbol whose modules are too small to survive being photographed off a
	/// screen. The subject below is sized so the **compact** link comes out at exactly
	/// `FindingShareLink.maximumCompactLength`, which is the largest symbol this app can ever print.
	///
	/// The field lengths are deliberate, not decorative:
	/// `https://link.aiarcheology.com/f#` (32) + `v=1` (3) + `&i=`+36 + `&t=`+40 + `&c=`+60
	/// + `&p=100` + `&g=48.80000,19.53000` + `&u=`+115 + `&a=`+60 + `&d=2026-08-17` = 400.
	///
	/// Re-derived for AIA-0657: the cap moved from 250 to 400 and the page is no longer dropped from
	/// this variant, so the old fixture would sit well under the new cap and quietly stop testing the
	/// densest symbol the app can print — which is the only thing this test is for.
	func test_qrCode_atTheCompactCap_decodesBackToTheSameFinding() throws {
		let id = try XCTUnwrap(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
		let title = String(repeating: "W", count: 40)
		let subject = makeSubject(
			id: id,
			title: title,
			author: String(repeating: "A", count: 60),
			gps: "48.8, 19.53",
			detectionClass: String(repeating: "c", count: 60),
			confidence: 1,
			date: try makeDate(year: 2026, month: 8, day: 17),
			// Carried now, and long enough to stand in for a real geoportal address.
			page: URL(string: "https://example.org/" + String(repeating: "p", count: 95))
		)

		let compact = try XCTUnwrap(FindingShareLink.url(for: subject.linkPayload(), variant: .compact))
		XCTAssertEqual(
			compact.absoluteString.count,
			FindingShareLink.maximumCompactLength,
			"The fixture must sit exactly on the cap; a shorter link makes this test prove nothing"
		)

		let code = try XCTUnwrap(
			FindingShareQRCode.image(for: compact),
			"A link at the documented cap must still produce a code"
		)
		XCTAssertEqual(code.cgImage?.width, Int(FindingShareQRCode.pixelSize))

		let decoded = try XCTUnwrap(
			decodedQRPayload(of: code),
			"Vision could not read the code — the symbol is too dense for the rendered size"
		)
		XCTAssertEqual(decoded, compact.absoluteString)

		let parsed = try XCTUnwrap(FindingShareLink.payload(from: try XCTUnwrap(URL(string: decoded))))
		XCTAssertEqual(parsed.id, id, "The scanned code must resolve to the same finding")
		XCTAssertEqual(parsed.title, title)
	}

	func test_qrCode_isGeneratedForAnOrdinaryFinding() throws {
		let subject = makeSubject()
		let art = FindingShareQRCode.cardLink(for: subject)
		XCTAssertEqual(art.address, FindingShareLink.webHost)
		XCTAssertNotNil(art.qrCode)
	}

	/// The address must survive on its own. A card is about to be posted publicly; a blank or
	/// half-drawn code box on it is worse than no box.
	func test_cardLink_withNoUsableTitle_keepsTheAddressAndDropsTheCode() {
		let art = FindingShareQRCode.cardLink(for: makeSubject(title: "   "))
		XCTAssertEqual(art.address, FindingShareLink.webHost)
		XCTAssertNil(art.qrCode)
	}

	// MARK: - Subject → payload

	func test_linkPayload_mapsEveryField() throws {
		let id = try XCTUnwrap(UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301"))
		let subject = makeSubject(id: id, date: try makeDate(year: 2026, month: 8, day: 17))
		let payload = subject.linkPayload()

		XCTAssertEqual(payload.id, id)
		XCTAssertEqual(payload.title, "Roman wall")
		XCTAssertEqual(payload.detectionClass, "stone_wall")
		XCTAssertEqual(payload.confidencePercent, 87)
		XCTAssertEqual(payload.coordinate, FindingShareLink.Coordinate(latitude: 48.8, longitude: 19.53))
		XCTAssertEqual(payload.author, "V. Slavík")
		XCTAssertEqual(payload.page?.absoluteString, "https://example.org/ruins")
		XCTAssertEqual(payload.date, DateComponents(year: 2026, month: 8, day: 17))
	}

	/// The common case, not the exceptional one: `gps_` is a free `TextField` that nothing in the app
	/// validates or fills in, so most findings carry prose or nothing at all.
	func test_linkPayload_gpsThatDoesNotParse_yieldsNoCoordinate() {
		for raw in ["behind the old mill", "48.8", "N/A", "", "1e5, 2", "-48.8N, 19.53E"] {
			XCTAssertNil(
				makeSubject(gps: raw).linkPayload().coordinate,
				"\(raw) must not become a coordinate"
			)
		}
	}

	func test_linkPayload_roundsConfidenceToWholePercent() {
		XCTAssertEqual(makeSubject(confidence: 0.874).linkPayload().confidencePercent, 87)
		XCTAssertEqual(makeSubject(confidence: 0.875).linkPayload().confidencePercent, 88)
		XCTAssertEqual(makeSubject(confidence: 0.876).linkPayload().confidencePercent, 88)
		XCTAssertEqual(makeSubject(confidence: 0).linkPayload().confidencePercent, 0)
		XCTAssertEqual(makeSubject(confidence: 1).linkPayload().confidencePercent, 100)
	}

	/// `Payload` validates nothing on construction, so an out-of-range percent would be emitted and
	/// then silently dropped by the parser — a link this app could not fully read back.
	func test_linkPayload_clampsAnImpossibleConfidence() {
		XCTAssertEqual(makeSubject(confidence: 1.4).linkPayload().confidencePercent, 100)
		XCTAssertEqual(makeSubject(confidence: -0.2).linkPayload().confidencePercent, 0)
		XCTAssertNil(makeSubject(confidence: .nan).linkPayload().confidencePercent)
	}

	/// The values that actually crashed.
	///
	/// The clamp above passed from the start, because 1.4 and -0.2 are small enough that the old
	/// `min(100, max(0, Int(x * 100)))` never reached the trap — the `Int(_:)` conversion ran FIRST
	/// and only then was the result clamped, so any value whose ×100 leaves `Int`'s range took the
	/// process down before the clamp could run. `Finding.detectionConfidence` is an unconstrained
	/// Core Data `Double`, so one corrupt or imported row was enough to crash the app on share.
	func test_linkPayload_hugeFiniteConfidenceIsClampedRatherThanTrapping() {
		for confidence in [
			Double.greatestFiniteMagnitude,
			-Double.greatestFiniteMagnitude,
			1e300,
			-1e300,
			Double(Int.max),
			Double(Int.min)
		] {
			let percent = makeSubject(confidence: confidence).linkPayload().confidencePercent
			XCTAssertNotNil(percent, "\(confidence) is finite, so it must produce a value")
			XCTAssertTrue((0...100).contains(percent ?? -1), "\(confidence) produced \(percent as Any)")
		}
	}

	func test_linkPayload_infiniteConfidenceIsDropped() {
		XCTAssertNil(makeSubject(confidence: .infinity).linkPayload().confidencePercent)
		XCTAssertNil(makeSubject(confidence: -.infinity).linkPayload().confidencePercent)
	}

	func test_linkPayload_absentOptionalsStayAbsent() {
		let payload = makeSubject(
			author: nil,
			gps: nil,
			detectionClass: nil,
			date: nil,
			page: nil
		).linkPayload()

		XCTAssertNil(payload.author)
		XCTAssertNil(payload.coordinate)
		XCTAssertNil(payload.detectionClass)
		XCTAssertNil(payload.date)
		XCTAssertNil(payload.page)
		XCTAssertEqual(payload.title, "Roman wall")
	}

	/// The page is reduced **before** the payload exists. The builder emits `page` verbatim, so an
	/// unreduced URL would carry the browsed query string — session tokens and all — inside the link
	/// that gets posted, and only the recipient's parser would drop it.
	func test_linkPayload_reducesThePageBeforeItCanBeEmitted() throws {
		let subject = makeSubject(page: URL(string: "https://example.org/a/b?session=secret#frag"))
		XCTAssertEqual(subject.linkPayload().page?.absoluteString, "https://example.org/a/b")

		let link = try XCTUnwrap(FindingShareLink.url(for: subject.linkPayload()))
		XCTAssertFalse(link.absoluteString.contains("session"), "The emitted link must not carry the query")
	}

	// MARK: - The box, and the sender's address choice (AIA-0657)

	/// The conversion is the point: `captureNormalizedBox` is a Vision rect (bottom-left origin) and
	/// the wire is top-left, so a box sitting in the **bottom** 25% of the capture must travel as
	/// one sitting in the **top** 75% down.
	func test_linkPayload_convertsTheBoxFromVisionToTopLeftOrigin() throws {
		let subject = makeSubject(captureNormalizedBox: CGRect(x: 0.1, y: 0.0, width: 0.4, height: 0.25))
		let box = try XCTUnwrap(subject.linkPayload().box)

		XCTAssertEqual(box.x, 0.1, accuracy: 1e-9)
		XCTAssertEqual(box.y, 0.75, accuracy: 1e-9, "Vision's bottom-left origin was not flipped")
		XCTAssertEqual(box.width, 0.4, accuracy: 1e-9)
		XCTAssertEqual(box.height, 0.25, accuracy: 1e-9)
	}

	/// `.zero` is what a row saved before capture boxes were stored carries, and it is not a
	/// location.
	func test_linkPayload_carriesNoBoxForAZeroRect() {
		XCTAssertNil(makeSubject(captureNormalizedBox: .zero).linkPayload().box)
	}

	/// The bug AIA-0761 fixed, pinned from both sides: once the save sheet has baked a crop into the
	/// image, `normalizedBox` is crop-relative and only `captureNormalizedBox` says where the
	/// detection sat on the page the recipient will open. Reverting the emission to `normalizedBox`
	/// has to fail here, so the wrong-source values are asserted absent as well as the right ones
	/// present.
	func test_linkPayload_statesTheCaptureBoxAndNotTheImageOne() throws {
		let subject = makeSubject(
			normalizedBox: CGRect(x: 0.6, y: 0.5, width: 0.25, height: 0.4),
			captureNormalizedBox: CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.2)
		)
		let box = try XCTUnwrap(subject.linkPayload().box)

		XCTAssertEqual(box.x, 0.2, accuracy: 1e-9)
		XCTAssertEqual(box.y, 0.7, accuracy: 1e-9)
		XCTAssertEqual(box.width, 0.3, accuracy: 1e-9)
		XCTAssertEqual(box.height, 0.2, accuracy: 1e-9)

		XCTAssertNotEqual(box.x, 0.6, accuracy: 1e-9, "The image-space box was emitted")
		XCTAssertNotEqual(box.y, 0.1, accuracy: 1e-9, "The image-space box was emitted")
		XCTAssertNotEqual(box.width, 0.25, accuracy: 1e-9, "The image-space box was emitted")
		XCTAssertNotEqual(box.height, 0.4, accuracy: 1e-9, "The image-space box was emitted")
	}

	/// A legacy row has a perfectly usable image-space box and no capture-space one. Emitting the
	/// former would hand the recipient a rectangle measured against a crop they will never see, so
	/// the link must carry no box at all rather than a fabricated one.
	func test_linkPayload_carriesNoBoxWhenOnlyTheImageBoxWasRecorded() {
		let subject = makeSubject(
			normalizedBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
			captureNormalizedBox: .zero
		)
		XCTAssertNil(subject.linkPayload().box)
	}

	func test_linkPayload_carriesTheFullAddressOnlyWhenAsked() throws {
		let raw = "https://portal.example.org/view?wmcid=5556&x=-556000"
		let subject = makeSubject(page: URL(string: raw))

		XCTAssertEqual(subject.linkPayload().page?.absoluteString, "https://portal.example.org/view")
		XCTAssertEqual(subject.linkPayload(pageDetail: .full).page?.absoluteString, raw)
	}

	// MARK: - Withholding the location

	/// Turning the location off must take the coordinate out of the **link**, not only off the card.
	///
	/// The card is the visible artifact and the obvious one to gate; the link is the one that would
	/// have kept working. A recipient opening a link whose card printed no coordinate would still be
	/// shown the map pin, which is the exact opposite of what the sender asked for.
	func test_withholdingLocation_takesTheCoordinateOutOfTheLink() {
		let subject = makeSubject(gps: "leaflet: 48.8, 19.53")

		XCTAssertNotNil(subject.linkPayload().coordinate, "precondition: this subject has a coordinate")
		XCTAssertNil(
			subject.withholdingLocation().linkPayload().coordinate,
			"the coordinate survived in the link after the sender withheld the location"
		)
	}

	/// Everything that is not the location must be untouched — a withheld coordinate is not a
	/// redacted finding.
	func test_withholdingLocation_changesNothingElse() throws {
		let date = try makeDate(year: 2026, month: 3, day: 4)
		let subject = makeSubject(
			normalizedBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
			captureNormalizedBox: CGRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2),
			date: date
		)
		let withheld = subject.withholdingLocation()

		XCTAssertEqual(withheld.id, subject.id)
		XCTAssertEqual(withheld.title, subject.title)
		XCTAssertEqual(withheld.author, subject.author)
		XCTAssertEqual(withheld.detectionClass, subject.detectionClass)
		XCTAssertEqual(withheld.confidence, subject.confidence)
		XCTAssertEqual(withheld.date, subject.date)
		XCTAssertEqual(withheld.page, subject.page)
		XCTAssertEqual(withheld.normalizedBox, subject.normalizedBox)
		XCTAssertEqual(withheld.captureNormalizedBox, subject.captureNormalizedBox)
		XCTAssertNil(withheld.gps)
	}

	/// The share sheet is where the sender's choice actually leaves the app, so the passthrough is
	/// asserted on the emitted item rather than on the payload it was built from.
	func test_items_carryTheAddressDetailTheSenderChose() throws {
		let raw = "https://portal.example.org/view?wmcid=5556"
		let subject = makeSubject(page: URL(string: raw))

		let full = FindingShareActivity.items(
			image: makeCardImage(), subject: subject, isLinkEnabled: true, includesLink: true, pageDetail: .full
		)
		let reduced = FindingShareActivity.items(
			image: makeCardImage(), subject: subject, isLinkEnabled: true, includesLink: true, pageDetail: .siteOnly
		)

		let fullLink = try XCTUnwrap(full.compactMap { $0 as? String }.first)
		let reducedLink = try XCTUnwrap(reduced.compactMap { $0 as? String }.first)

		XCTAssertEqual(
			FindingShareLink.payload(from: try XCTUnwrap(URL(string: fullLink)))?.page?.absoluteString,
			raw
		)
		XCTAssertEqual(
			FindingShareLink.payload(from: try XCTUnwrap(URL(string: reducedLink)))?.page?.absoluteString,
			"https://portal.example.org/view"
		)
	}

	/// The composer's address control has to change the **printed code**, not just the printed text.
	///
	/// Asserted by decoding the generated bitmap rather than by reading the state that decides it:
	/// the failure this guards against was precisely a state variable saying one thing while the
	/// image said another, so trusting that variable would reproduce the bug inside its own test.
	func test_cardLink_regeneratesTheCodeWhenTheAddressDetailChanges() throws {
		let raw = "https://portal.example.org/view?wmcid=5556&x=-556000"
		let subject = makeSubject(page: URL(string: raw))

		let full = FindingShareQRCode.cardLink(for: subject, pageDetail: .full)
		let reduced = FindingShareQRCode.cardLink(for: subject, pageDetail: .siteOnly)

		let fullDecoded = try XCTUnwrap(decodedQRPayload(of: try XCTUnwrap(full.qrCode)))
		let reducedDecoded = try XCTUnwrap(decodedQRPayload(of: try XCTUnwrap(reduced.qrCode)))

		XCTAssertEqual(
			FindingShareLink.payload(from: try XCTUnwrap(URL(string: fullDecoded)))?.page?.absoluteString,
			raw,
			"the printed code did not carry the address the sender was shown"
		)
		XCTAssertEqual(
			FindingShareLink.payload(from: try XCTUnwrap(URL(string: reducedDecoded)))?.page?.absoluteString,
			"https://portal.example.org/view",
			"reducing the address left the code encoding the full one"
		)
	}

	func test_linkPayload_dropsANonHTTPSPage() {
		XCTAssertNil(makeSubject(page: URL(string: "http://example.org/x")).linkPayload().page)
	}

	// MARK: - Share-sheet items

	func test_activityItems_withTheFeatureFlagOff_carryTheImageAlone() {
		let image = makeCardImage()
		let items = FindingShareActivity.items(
			image: image,
			subject: makeSubject(),
			isLinkEnabled: false,
			includesLink: true
		)

		XCTAssertEqual(items.count, 1)
		XCTAssertTrue(items[0] is UIImage)
	}

	func test_activityItems_withTheToggleOff_carryTheImageAlone() {
		let items = FindingShareActivity.items(
			image: makeCardImage(),
			subject: makeSubject(),
			isLinkEnabled: true,
			includesLink: false
		)

		XCTAssertEqual(items.count, 1)
		XCTAssertTrue(items[0] is UIImage)
	}

	/// The second item's **type** is the assertion, not its text. A `URL` there would make
	/// LinkPresentation fetch the address from this device to build the sheet's header — an outbound
	/// request behind a purely local action — and would hide the image behind a link preview.
	func test_activityItems_withTheFeatureOn_carryTheImageAndTheLinkAsAString() throws {
		let subject = makeSubject()
		let items = FindingShareActivity.items(
			image: makeCardImage(),
			subject: subject,
			isLinkEnabled: true,
			includesLink: true
		)

		XCTAssertEqual(items.count, 2)
		XCTAssertTrue(items[0] is UIImage)
		XCTAssertTrue(items[1] is String, "The link must travel as a String")
		XCTAssertFalse(items[1] is URL, "A URL item changes how the sheet behaves and what it fetches")

		let expected = try XCTUnwrap(FindingShareLink.url(for: subject.linkPayload()))
		XCTAssertEqual(items[1] as? String, expected.absoluteString)
	}

	/// A finding whose title is nothing but whitespace cannot produce a link, and the share must
	/// still work — as an image, exactly as it did before the feature existed.
	func test_activityItems_whenNoLinkCanBeBuilt_fallBackToTheImageAlone() {
		let items = FindingShareActivity.items(
			image: makeCardImage(),
			subject: makeSubject(title: "   "),
			isLinkEnabled: true,
			includesLink: true
		)

		XCTAssertEqual(items.count, 1)
	}
}
