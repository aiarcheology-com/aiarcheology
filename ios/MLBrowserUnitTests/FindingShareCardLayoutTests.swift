//
//  FindingShareCardLayoutTests.swift
//  MLBrowserUnitTests
//
//  Where the link badge sits on the share card, and whether the text still fits beside it
//  (AIA-0657). The defect these exist for was reported from screenshots of a real build, so they
//  assert against a *render* rather than against the view tree.
//

import SwiftUI
import UIKit
import XCTest
@testable import ML_Browser

@MainActor
final class FindingShareCardLayoutTests: XCTestCase {

	// MARK: - Helpers

	/// A subject with a controllable number of metadata rows. Two and seven are the bounds the
	/// ticket names.
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
		layoutDirection: LayoutDirection = .leftToRight
	) throws -> (image: UIImage, scale: CGFloat) {
		let card = FindingShareCard(subject: subject, orientation: orientation, link: makeLink())
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
		// 79 modules is the 400-character worst case: 77 plus the generator's quiet zone.
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
}
