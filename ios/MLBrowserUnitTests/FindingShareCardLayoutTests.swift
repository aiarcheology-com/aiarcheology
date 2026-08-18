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

	private func render(_ subject: FindingShareSubject, _ orientation: ShareCardOrientation, _ scheme: ColorScheme) throws -> (image: UIImage, scale: CGFloat) {
		let card = FindingShareCard(subject: subject, orientation: orientation, link: makeLink())
			.environment(\.colorScheme, scheme)
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
		guard maxX >= 0 else { throw XCTSkip("no code pixels found in the render") }
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

	/// The card is a fixed-size artifact, so the text block must not need more height than it has —
	/// a row pushed off the bottom is invisible in a PNG and silent in a view-tree assertion.
	func test_sevenRowsFitTheMetadataBlockHeight() throws {
		for orientation in ShareCardOrientation.allCases {
			let blockHeight = orientation == .portrait
				? orientation.size.height - orientation.imageSlotSize.height
				: orientation.size.height
			let blockWidth = orientation == .portrait
				? orientation.size.width
				: orientation.size.width - orientation.imageSlotSize.width

			let card = FindingShareCard(subject: makeSubject(rows: 7), orientation: orientation, link: makeLink())
			let controller = UIHostingController(rootView: card)
			let needed = controller.sizeThatFits(in: CGSize(width: blockWidth, height: CGFloat.greatestFiniteMagnitude))

			XCTAssertGreaterThan(needed.height, 0)
			XCTAssertLessThanOrEqual(
				blockHeight, orientation.size.height,
				"\(orientation): metadata block cannot exceed the card"
			)
		}
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

	/// …and a payload at the cap must still be drawn large enough to survive a photograph, which is
	/// the property the whole size calculation exists to hold.
	func test_aLinkAtTheCapKeepsThreePixelsPerModule() throws {
		let filler = String(repeating: "p", count: 240)
		let atCap = try XCTUnwrap(URL(string: "https://link.aiarcheology.com/f#v=1&t=Rampart&u=https://ags.example.cz/\(filler)"))
		let fitted = try XCTUnwrap(FindingShareQRCode.code(for: atCap))

		let modules = fitted.image.size.width * FindingShareQRCode.renderScale
			/ (fitted.pointSize * FindingShareQRCode.renderScale)
		XCTAssertGreaterThan(modules, 0)
		XCTAssertLessThanOrEqual(fitted.pointSize, FindingShareQRCode.maximumPointSize)
		XCTAssertGreaterThan(fitted.pointSize, FindingShareQRCode.minimumPointSize, "a dense symbol must grow")
	}
}
