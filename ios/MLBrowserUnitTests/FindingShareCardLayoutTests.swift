//
//  FindingShareCardLayoutTests.swift
//  MLBrowserUnitTests
//
//  Where the link badge sits on the share card, and whether the text still fits beside it
//  (AIA-0657). The defect these exist for was reported from screenshots of a real build, so they
//  assert against a *render* rather than against the view tree.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import XCTest
@testable import ML_Browser

@MainActor
final class FindingShareCardLayoutTests: XCTestCase {

	// MARK: - Helpers

	/// A subject with a controllable number of metadata rows. Two and seven are the bounds the
	/// ticket names.
	/// The same subject twice, differing ONLY in how long its coordinate is.
	///
	/// Comparing subjects with different row counts would measure the extra rows rather than the
	/// wrapping, which is exactly what the first version of this test did.
	private func makeCoordinateSubject(gps: String) -> FindingShareSubject {
		FindingShareSubject(
			id: UUID(),
			title: "dsds",
			label: nil,
			note: nil,
			author: nil,
			gps: gps,
			detectionClass: "f7",
			confidence: 0.46,
			host: "ags.cuzk.cz",
			date: Date(timeIntervalSince1970: 1_780_000_000),
			page: URL(string: "https://ags.cuzk.cz/av/")
		)
	}

	private func makeSubject(rows: Int, host: String = "geoportal.example.cz") -> FindingShareSubject {
		FindingShareSubject(
			id: UUID(),
			title: "Overgrown rampart on the north ridge",
			label: rows >= 4 ? "rampart" : nil,
			note: rows >= 5 ? "Follows the contour for roughly two hundred metres." : nil,
			author: rows >= 3 ? "V. Slavík" : nil,
			gps: rows >= 6 ? "48.80000, 19.53000" : nil,
			detectionClass: rows >= 7 ? "earthwork" : nil,
			confidence: 0.82,
			host: host,
			date: rows >= 2 ? Date(timeIntervalSince1970: 1_780_000_000) : nil,
			page: URL(string: "https://\(host)/geoprohlizec/")
		)
	}

	private func makeLink() -> FindingShareCardLink {
		FindingShareCardLink(address: FindingShareLink.webHost, qrCode: makeCode())
	}

	/// A solid **magenta** square standing in for the code.
	///
	/// Not black, and not white. The badge's own background is white and so is `systemBackground` in
	/// light mode, so a white-seeking scan selects the entire card; black collides with the metadata
	/// text. A colour that appears nowhere else on the card makes the code locatable in a render
	/// under either appearance, which is the whole point of asserting against pixels rather than
	/// against the view tree.
	private func makeCode() -> UIImage {
		UIGraphicsImageRenderer(size: CGSize(width: 66, height: 66)).image { context in
			UIColor.magenta.setFill()
			context.fill(CGRect(x: 0, y: 0, width: 66, height: 66))
		}
	}

	private func render(
		_ subject: FindingShareSubject,
		_ orientation: ShareCardOrientation,
		_ scheme: ColorScheme,
		layoutDirection: LayoutDirection = .leftToRight,
		badge: Bool = true
	) throws -> (image: UIImage, scale: CGFloat) {
		let card = FindingShareCard(subject: subject, orientation: orientation, link: badge ? makeLink() : nil)
			.environment(\.colorScheme, scheme)
			.environment(\.layoutDirection, layoutDirection)
		let renderer = ImageRenderer(content: card)
		renderer.scale = 2
		let image = try XCTUnwrap(renderer.uiImage, "the card did not render")
		return (image, 2)
	}

	/// Locates the stand-in code in a rendered card by colour, rather than asking the view tree where
	/// it thinks it put something — which is the question that answered correctly while the card
	/// looked wrong.
	private func codeRect(in image: UIImage, scale: CGFloat) throws -> CGRect {
		let cgImage = try XCTUnwrap(image.cgImage)
		let width = cgImage.width
		let height = cgImage.height
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let context = try XCTUnwrap(CGContext(
			data: &pixels,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: width * 4,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		))
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

		var minX = width, minY = height, maxX = -1, maxY = -1
		for y in 0..<height {
			for x in 0..<width {
				let offset = (y * width + x) * 4
				let isMagenta = pixels[offset] > 200 && pixels[offset + 1] < 80 && pixels[offset + 2] > 200
				guard isMagenta else { continue }
				minX = min(minX, x); maxX = max(maxX, x)
				minY = min(minY, y); maxY = max(maxY, y)
			}
		}
		// A failure, not a skip. If the badge stops rendering at all, every assertion built on this
		// helper would otherwise go green-by-skip — which is the loudest possible regression reported
		// as silence.
		guard maxX >= 0 else {
			XCTFail("no code pixels in the render — the badge did not draw")
			return .zero
		}
		return CGRect(
			x: CGFloat(minX) / scale,
			y: CGFloat(minY) / scale,
			width: CGFloat(maxX - minX + 1) / scale,
			height: CGFloat(maxY - minY + 1) / scale
		)
	}

	// MARK: - The corner

	/// **Two rows, not seven.** Two rows is the only case that exercises both anchors at once: a
	/// seven-row card passes with the trailing frame missing (the rows are wide enough to push the
	/// badge right anyway) *and* with the spacer missing (the rows are tall enough to push it down
	/// anyway). The reported defect was precisely a card that looked fine when full.
	func test_badgeIsFlushToTheTrailingEdgeOfTheMetadataBlock() throws {
		// The block's padding plus the badge's own padding around the code.
		let expectedGap: CGFloat = 16 + 5

		for orientation in ShareCardOrientation.allCases {
			for scheme in [ColorScheme.light, .dark] {
				let (image, scale) = try render(makeSubject(rows: 2), orientation, scheme)
				let code = try codeRect(in: image, scale: scale)

				XCTAssertEqual(
					orientation.size.width - code.maxX, expectedGap, accuracy: 2,
					"\(orientation)/\(scheme): the code is not flush to the trailing edge — "
						+ "a VStack sizes to its widest child, so the badge follows the longest row "
						+ "unless the text column is given maxWidth: .infinity"
				)
			}
		}
	}

	/// The reported defect was the badge moving with the *content* rather than sitting on the block.
	/// Stated as an invariance: its distance from the card's bottom edge must not change between two
	/// rows and seven. Absolute metrics would drag the caption's font metrics into the assertion; the
	/// invariance is the property the ticket actually asks for.
	func test_theBadgeSitsInTheSamePlaceAtEveryRowCount() throws {
		for orientation in ShareCardOrientation.allCases {
			var gaps: [CGFloat] = []
			for rows in 2...7 {
				let (image, scale) = try render(makeSubject(rows: rows), orientation, .light)
				let code = try codeRect(in: image, scale: scale)
				gaps.append(orientation.size.height - code.maxY)
			}
			let spread = (gaps.max() ?? 0) - (gaps.min() ?? 0)
			XCTAssertLessThanOrEqual(
				spread, 2,
				"\(orientation): the badge moved \(spread)pt between two rows and seven — "
					+ "without the trailing Spacer the column stops filling the block and the badge floats"
			)
		}
	}

	/// The corner is the **trailing** one, not "the right one", so under a right-to-left layout the
	/// badge mirrors to the bottom left along with the text it sits beside.
	///
	/// Free from `HStack` in principle — it lays out along the layout direction — but `ar`, `he` and
	/// `fa` are shipping locales and a card is an image a user posts publicly, so "in principle" is
	/// not the standard. Asserted on a render, in both orientations.
	func test_theBadgeMirrorsToTheOtherCornerInRightToLeftLayouts() throws {
		for orientation in ShareCardOrientation.allCases {
			let (image, scale) = try render(makeSubject(rows: 3), orientation, .light, layoutDirection: .rightToLeft)
			let code = try codeRect(in: image, scale: scale)

			XCTAssertEqual(
				code.minX, 16 + 5, accuracy: 2,
				"\(orientation): the code did not mirror to the leading (left) edge under RTL"
			)
			XCTAssertLessThan(
				code.maxX, orientation.size.width / 2,
				"\(orientation): the code is still on the right in an RTL layout"
			)
		}
	}

	// MARK: - What the badge costs the text beside it

	/// E3, decided by measurement rather than by preference: the badge reserves its own width, so
	/// the host row — the degraded floor the ticket forbids losing — must still fit in what is left.
	///
	/// Landscape is the tight case: a 640pt card gives the metadata block 44% of its width.
	func test_theHostRowFitsBesideTheBadgeInBothOrientations() throws {
		let host = "www.openstreetmap.org"
		for orientation in ShareCardOrientation.allCases {
			let blockWidth = orientation.size.width - orientation.imageSlotSize.width
			let available = (orientation == .portrait ? orientation.size.width : blockWidth)
				- 32                                   // the block's own padding
				- FindingShareLinkBadge.maximumWidth
				- 12                                   // the gap between column and badge

			let row = Label(host, systemImage: "globe").font(.caption)
			let controller = UIHostingController(rootView: row)
			let needed = controller.sizeThatFits(in: CGSize(width: 10_000, height: 10_000)).width

			XCTAssertGreaterThanOrEqual(
				available, needed,
				"\(orientation): the host row needs \(needed)pt but only \(available)pt is left beside the badge"
			)
		}
	}

	/// The seventh row must actually be **drawn**, not merely fit on paper.
	///
	/// The superseded version of this test compared two constants derived from `orientation.size` and
	/// could not fail whatever the layout did. This one renders six rows and seven and counts the ink
	/// in the metadata block: if the last row is clipped off the bottom, or squeezed out by the badge
	/// beside it, the seven-row card has no more marks on it than the six-row one.
	/// A projected coordinate must not lose its NUMBERS to truncation.
	///
	/// Reported from a shared card: `S-JTSK (EPSG:5514): -8195…` — the label survived and the digits
	/// did not, which tells a reader what kind of coordinate it is and not where it is. The two
	/// subjects here are identical apart from the coordinate's length, so a taller render can only
	/// mean the row wrapped rather than being cut.
	func test_aProjectedCoordinateKeepsItsDigitsInBothOrientations() throws {
		for orientation in ShareCardOrientation.allCases {
			let (long, scale) = try render(
				makeCoordinateSubject(gps: "S-JTSK (EPSG:5514): -819500.4472281, -1032881.7596427"),
				orientation, .dark
			)
			let (short, _) = try render(makeCoordinateSubject(gps: "48.8, 19.53"), orientation, .dark)
			let longRows = try inkRows(in: long, scale: scale)
			let shortRows = try inkRows(in: short, scale: scale)
			XCTAssertGreaterThan(
				longRows, shortRows,
				"\(orientation): a coordinate carrying its CRS drew no extra line — it is being truncated"
			)
		}
	}

	// MARK: - The note

	/// The same subject at every row the card can draw, differing only in the note.
	private func makeNoteSubject(note: String) -> FindingShareSubject {
		FindingShareSubject(
			id: UUID(),
			title: "Overgrown rampart on the north ridge",
			label: "rampart",
			note: note,
			author: "V. Slavík",
			gps: "48.80000, 19.53000",
			detectionClass: "earthwork",
			confidence: 0.82,
			host: "geoportal.example.cz",
			date: Date(timeIntervalSince1970: 1_780_000_000),
			page: URL(string: "https://geoportal.example.cz/geoprohlizec/")
		)
	}

	/// A long note must use the room the landscape block actually has.
	///
	/// Reported from a build: the note truncated after two lines with the lower half of the metadata
	/// block empty. Asserted in **ink rows**, because the card is a fixed size — its overall extent
	/// says nothing — and asserted only in landscape, which is the orientation with slack: the
	/// portrait block is nearly full at four lines already, so the same measurement there would be
	/// pinning the absence of a defect rather than its fix.
	func test_aLongNoteUsesTheLandscapeBlocksSpareLines() throws {
		let (long, scale) = try render(makeNoteSubject(note: Self.longNote), .landscape, .light, badge: false)
		let (short, _) = try render(makeNoteSubject(note: "Follows the contour."), .landscape, .light, badge: false)

		let extra = try inkRowsInMetadata(in: long, scale: scale, .landscape)
			- inkRowsInMetadata(in: short, scale: scale, .landscape)
		// A caption line box is ~14pt, but only its *inked* rows are counted — measured at ~18 pixel
		// rows per line at scale 2, the rest being leading. Nine extra lines therefore measure ~166;
		// the two-line cap this replaces could add at most one, about 18. Six lines' worth is the
		// threshold: far beyond the old behaviour, comfortably inside the new.
		XCTAssertGreaterThan(
			extra, 6 * 18,
			"a long note added only \(extra) pixel rows — it is still being truncated with the block half empty"
		)
	}

	/// The rows *below* the note must survive a note long enough to fill the block.
	///
	/// The mirror of the test above: room for the note is worth nothing if it is taken from the
	/// coordinate, the host and the date underneath it.
	func test_aLongNoteDoesNotCrowdOutTheCoordinate() throws {
		for orientation in ShareCardOrientation.allCases {
			let subject = makeNoteSubject(note: Self.longNote)
			let (present, scale) = try render(subject, orientation, .light, badge: false)
			let (absent, _) = try render(subject.withholdingLocation(), orientation, .light, badge: false)
			XCTAssertGreaterThan(
				try inkRowsInMetadata(in: present, scale: scale, orientation),
				try inkRowsInMetadata(in: absent, scale: scale, orientation),
				"\(orientation): the coordinate row drew nothing beside a long note — it was crowded out"
			)
		}
	}

	/// Pixel rows carrying ink **inside the metadata block**, whichever side of the card it is on.
	///
	/// Not `inkRows`, which samples the right-hand half of the image. That is the metadata block in
	/// landscape and only *part* of it in portrait, where the block is full-width — and a caption row
	/// like `48.80000, 19.53000` is about 100pt wide, so it never reaches the sampled half and
	/// counted as nothing. The first version of the crowding test measured 172 rows with and without
	/// the coordinate for exactly that reason: the instrument could not see the row it was about.
	private func inkRowsInMetadata(
		in image: UIImage,
		scale: CGFloat,
		_ orientation: ShareCardOrientation
	) throws -> Int {
		let cgImage = try XCTUnwrap(image.cgImage)
		let width = cgImage.width, height = cgImage.height
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let context = try XCTUnwrap(CGContext(
			data: &pixels, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		))
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

		let originX = orientation == .portrait ? 0 : Int(orientation.imageSlotSize.width * scale)
		let originY = orientation == .portrait ? Int(orientation.imageSlotSize.height * scale) : 0
		var rows = 0
		for y in originY..<height {
			for x in originX..<width {
				let i = (y * width + x) * 4
				if pixels[i] < 200 || pixels[i + 1] < 200 || pixels[i + 2] < 200 { rows += 1; break }
			}
		}
		return rows
	}

	/// Long enough to exhaust any line cap either orientation could reasonably have.
	private static let longNote = String(
		repeating: "Follows the contour for roughly two hundred metres before it turns. ",
		count: 8
	)

	/// How many pixel rows carry ink in the metadata column.
	///
	/// The card is a fixed size, so its overall drawn extent does not change when a row wraps — the
	/// first version of this test measured that and learned nothing. An extra line of text does add
	/// ink rows, so those are counted, and only in the right-hand column where the metadata sits so
	/// the snapshot image cannot dominate the measurement.
	private func inkRows(in image: UIImage, scale: CGFloat) throws -> Int {
		let cgImage = try XCTUnwrap(image.cgImage)
		let width = cgImage.width, height = cgImage.height
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let context = try XCTUnwrap(CGContext(
			data: &pixels, width: width, height: height, bitsPerComponent: 8,
			bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		))
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

		// Sample the background from a corner of the metadata side.
		let sampleIndex = (8 * width + (width - 8)) * 4
		let background = (pixels[sampleIndex], pixels[sampleIndex + 1], pixels[sampleIndex + 2])
		let columnStart = width / 2
		var rows = 0
		for y in 0..<height {
			for x in columnStart..<width {
				let i = (y * width + x) * 4
				if abs(Int(pixels[i]) - Int(background.0)) > 40
					|| abs(Int(pixels[i + 1]) - Int(background.1)) > 40
					|| abs(Int(pixels[i + 2]) - Int(background.2)) > 40 {
					rows += 1
					break
				}
			}
		}
		return rows
	}

	func test_theSeventhRowIsActuallyDrawn() throws {
		for orientation in ShareCardOrientation.allCases {
			let six = try inkInMetadata(of: makeSubject(rows: 6), orientation)
			let seven = try inkInMetadata(of: makeSubject(rows: 7), orientation)
			XCTAssertGreaterThan(
				seven, six,
				"\(orientation): a seventh row added no visible content — it is clipped or crowded out"
			)
		}
	}

	/// Counts non-background pixels in the metadata block of a rendered card.
	private func inkInMetadata(of subject: FindingShareSubject, _ orientation: ShareCardOrientation) throws -> Int {
		let (image, scale) = try render(subject, orientation, .light)
		let cgImage = try XCTUnwrap(image.cgImage)
		let width = cgImage.width
		let height = cgImage.height
		var pixels = [UInt8](repeating: 0, count: width * height * 4)
		let context = try XCTUnwrap(CGContext(
			data: &pixels,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: width * 4,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		))
		context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

		// The metadata block only: below the image in portrait, right of it in landscape.
		let originX = orientation == .portrait ? 0 : Int(orientation.imageSlotSize.width * scale)
		let originY = orientation == .portrait ? Int(orientation.imageSlotSize.height * scale) : 0

		var ink = 0
		for y in originY..<height {
			for x in originX..<width {
				let offset = (y * width + x) * 4
				// Anything meaningfully darker than the light-mode background counts as a mark.
				if pixels[offset] < 200 || pixels[offset + 1] < 200 || pixels[offset + 2] < 200 { ink += 1 }
			}
		}
		return ink
	}

	// MARK: - The coordinate is never cut

	/// **If a coordinate is on the card it is on the card whole.**
	///
	/// Measured against the SHIPPED row rather than a copy of it, which is why the row is its own
	/// view: re-adding any line cap makes the shipped row shorter than the text needs, and this
	/// fails. The previous rule — two lines with a 0.75 scale factor — passed the older ink-row test
	/// while still cutting a real coordinate on a real card, because more ink is not the same claim
	/// as nothing missing.
	@MainActor
	func test_aProjectedCoordinateIsNeverTruncated() throws {
		// Reported from a build, verbatim: 57 characters against a column about 170pt wide.
		let gps = "Web Mercator (EPSG:3857): 1134425.9924799, 6045439.9357442"
		let width = FindingShareCoordinateRow.narrowestTextColumn

		let shipped = UIHostingController(rootView: FindingShareCoordinateRow(gps: gps))
			.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
		let uncut = UIHostingController(
			rootView: Label(gps, systemImage: "location")
				.font(.caption)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
		).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))

		XCTAssertEqual(
			shipped.height, uncut.height, accuracy: 0.5,
			"the row is \(shipped.height)pt where the text needs \(uncut.height)pt — it is being cut"
		)
	}

	/// The measurement above is only meaningful if this string genuinely overflows the cap it broke.
	/// Without this, a column wide enough to fit it in two lines would make that test pass for the
	/// wrong reason.
	@MainActor
	func test_theReportedCoordinateNeedsMoreThanTwoLines() throws {
		let gps = "Web Mercator (EPSG:3857): 1134425.9924799, 6045439.9357442"
		let width = FindingShareCoordinateRow.narrowestTextColumn

		let full = UIHostingController(rootView: FindingShareCoordinateRow(gps: gps))
			.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
		let capped = UIHostingController(
			rootView: Label(gps, systemImage: "location")
				.font(.caption)
				.lineLimit(2)
				.minimumScaleFactor(0.75)
				.fixedSize(horizontal: false, vertical: true)
		).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height

		XCTAssertGreaterThan(
			full, capped,
			"this coordinate fits in two lines at \(width)pt, so it is the wrong witness for the defect"
		)
	}

	// MARK: - The badge's own floor

	/// When the compact link will not fit there is no code, and this caption is the only thing on the
	/// card naming where the finding came from. It must not truncate at the scale factor it is
	/// allowed to shrink to.
	func test_theBadgeCaptionIsNotTruncatedAtItsMinimumScale() throws {
		let caption = Text(verbatim: FindingShareLink.webHost)
			.font(.system(size: 8, weight: .semibold))
			.lineLimit(1)
		let controller = UIHostingController(rootView: caption)
		let needed = controller.sizeThatFits(in: CGSize(width: 10_000, height: 10_000)).width

		// Measured against the **smallest** code the badge can draw, which is the worst case for the
		// caption: the code shrinks with its payload, the address does not.
		XCTAssertLessThanOrEqual(
			needed * 0.7, FindingShareQRCode.minimumPointSize,
			"the address needs \(needed)pt and cannot fit \(FindingShareQRCode.minimumPointSize)pt even scaled to 0.7"
		)
	}

	// MARK: - The code costs only what its payload needs

	/// The badge is a ceiling, not a size. A short link must not reserve the space a 400-character
	/// one would.
	func test_aShortLinkProducesASmallerCodeThanTheCeiling() throws {
		let short = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=Rampart&u=https://ags.example.cz/av/"))
		let fitted = try XCTUnwrap(FindingShareQRCode.code(for: short))

		XCTAssertLessThan(fitted.pointSize, FindingShareQRCode.maximumPointSize)
		XCTAssertGreaterThanOrEqual(fitted.pointSize, FindingShareQRCode.minimumPointSize)
	}

	/// …and the size calculation must hold its stated invariant at every symbol size.
	///
	/// Asserted against `fittedPointSize` directly, as a pure function of the module count. The
	/// superseded version divided the bitmap width by the point size, which cancels to `renderScale`
	/// by construction and then asserted it was positive — true even if every module were drawn one
	/// pixel wide, the single failure this budget exists to prevent.
	func test_fittedPointSizeKeepsItsPixelsPerModuleUpToTheCeiling() {
		// 79 modules is the 400-character worst case: 77 plus the generator's quiet zone. The stride
		// stops there rather than at the ceiling's own capacity because beyond the budget the clamp
		// *does* bite: 91 modules would want 114pt, get 110, and fall to 3.62px per module. That is
		// not a bug in `fittedPointSize` — it is the reason `maximumCompactLength` has to be measured
		// against the ceiling, which `test_aLinkAtTheBudgetIsNotClampedByTheCeiling` pins (AIA-0836).
		for modules in stride(from: 21.0, through: 79.0, by: 2.0) {
			let points = FindingShareQRCode.fittedPointSize(moduleCount: modules)
			let pixelsPerModule = (points * FindingShareQRCode.renderScale) / modules
			XCTAssertGreaterThanOrEqual(
				pixelsPerModule, FindingShareQRCode.minimumPixelsPerModule,
				"a \(modules)-module symbol at \(points)pt gives \(pixelsPerModule)px per module"
			)
		}
	}

	/// A symbol denser than the floor can hold must actually grow, or the clamp would silently cap
	/// scannability instead of size.
	func test_aDenseSymbolGrowsBeyondTheFloor() {
		let atFloor = FindingShareQRCode.fittedPointSize(moduleCount: 40)
		let dense = FindingShareQRCode.fittedPointSize(moduleCount: 79)
		XCTAssertEqual(atFloor, FindingShareQRCode.minimumPointSize, "a small symbol should sit on the floor")
		XCTAssertGreaterThan(dense, FindingShareQRCode.minimumPointSize)
		XCTAssertLessThanOrEqual(dense, FindingShareQRCode.maximumPointSize)
	}

	/// The pairing AIA-0836 measured: a link at ``FindingShareLink/maximumCompactLength`` produces a
	/// symbol the ceiling does **not** have to clamp.
	///
	/// This is the test that stops a future budget rise from silently making printed cards
	/// unscannable. `fittedPointSize` clamps to the ceiling rather than reporting that it could not
	/// honour the floor, so raising `maximumCompactLength` without raising `maximumPointSize` costs
	/// nothing visible — the code still renders, at 3.7px per module instead of 3.75, and only a
	/// photographed card fails.
	///
	/// The symbol is generated here rather than derived from arithmetic, with the same generator and
	/// the same `"M"` correction level the badge uses: version-to-capacity is a property of the
	/// generator, which is exactly why the budget had to be measured rather than predicted. Strict
	/// inequality is the assertion that matters — equality with the ceiling is indistinguishable
	/// from having been clamped by it.
	func test_aLinkAtTheBudgetIsNotClampedByTheCeiling() throws {
		// Built to the cap rather than at a hardcoded filler length: the previous shape of this
		// fixture was arithmetic against a constant, which is precisely what stops being true the
		// next time the cap moves.
		let prefix = "https://\(FindingShareLink.webHost)\(FindingShareLink.path)#v=1&t=Rampart&u="
		let url = try XCTUnwrap(
			URL(string: prefix + String(repeating: "x", count: FindingShareLink.maximumCompactLength - prefix.count))
		)
		XCTAssertEqual(url.absoluteString.count, FindingShareLink.maximumCompactLength, "fixture drifted off the budget")

		let filter = CIFilter.qrCodeGenerator()
		filter.message = Data(url.absoluteString.utf8)
		filter.correctionLevel = "M"
		let modules = try XCTUnwrap(filter.outputImage?.extent.width)

		let points = FindingShareQRCode.fittedPointSize(moduleCount: modules)
		let pixelsPerModule = (points * FindingShareQRCode.renderScale) / modules

		XCTAssertLessThan(
			points, FindingShareQRCode.maximumPointSize,
			"a \(modules)-module symbol wants \(points)pt — the budget has outgrown the ceiling"
		)
		XCTAssertGreaterThanOrEqual(pixelsPerModule, FindingShareQRCode.minimumPixelsPerModule)
	}
}
