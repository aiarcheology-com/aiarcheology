//
//  FindingShareQRCode.swift
//  AI Archeology
//
//  The scannable half of the share card (AIA-0650): the short address, and the QR beside it.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - What the card prints

/// The link art printed onto a share card: the address a person can read, and — when one could be
/// generated — the code a phone can scan.
///
/// `qrCode` is optional and the card honours that by rendering the address alone. A blank or
/// half-drawn code box on an image that is about to be posted publicly is worse than no box at all.
struct FindingShareCardLink {
	let address: String
	let qrCode: UIImage?
}

// MARK: - Generation

enum FindingShareQRCode {

	/// The code's edge on the card, in points. The composer renders at `max(displayScale, 3)`, so
	/// this is at least 264px in the exported PNG.
	///
	/// Grown from 64pt for AIA-0657, and the growth *is* the budget. Scannability is decided by
	/// pixels per module, so carrying more characters means more modules, which means each one gets
	/// thinner unless the code gets physically bigger. At EC-M a 400-character payload is a
	/// version-15 symbol — 77 modules, 79 with the generator's quiet zone — and
	/// `floor(264 / 79) = 3`px per module, identical to what 250 characters at 64pt gave
	/// (`floor(192 / 63) = 3`). The code carries 60% more and is no harder to scan.
	static let pointSize: CGFloat = 88

	/// The render scale the composer guarantees. Used to size the generated bitmap for the pixels it
	/// will actually occupy rather than for the ~60px image the filter hands back.
	static let renderScale: CGFloat = 3

	static var pixelSize: CGFloat { pointSize * renderScale }

	/// The art for `subject`: always an address, and a code whenever the compact link fits.
	///
	/// The code carries the **compact** variant, never the full one, and that is the whole reason
	/// `FindingShareLink.Variant.compact` exists. A 900-character fragment payload forces QR byte
	/// mode and lands near a version-24 symbol — roughly 113 modules across — which at 264px is
	/// 2.3px per module and does not survive being photographed off a screen, the only way a
	/// reposted card is ever scanned. Both variants resolve to the same finding.
	///
	/// Since AIA-0657 the compact link carries the page address too, so the code and the string a
	/// sender posts name the same place. The compact ladder may still reduce that address to its
	/// host to fit — never to nothing — which is why the composer's preview is worded as the most
	/// that travels rather than the exact bytes of both artifacts.
	static func cardLink(
		for subject: FindingShareSubject,
		pageDetail: FindingShareLink.PageDetail = .siteOnly
	) -> FindingShareCardLink {
		let compact = FindingShareLink.url(
			for: subject.linkPayload(pageDetail: pageDetail),
			variant: .compact,
			pageDetail: pageDetail
		)
		return FindingShareCardLink(
			address: FindingShareLink.webHost,
			qrCode: compact.flatMap { image(for: $0) }
		)
	}

	/// Creating a `CIContext` sets up a GPU pipeline and is expensive, so one is reused — the same
	/// pattern as `UIImage.adjusted(brightness:contrast:saturation:)`. `CIContext` is thread-safe.
	private static let context = CIContext(options: nil)

	/// Renders `url` as a QR bitmap `pixelSize` pixels square, or `nil` if it cannot be encoded.
	static func image(for url: URL, pixelSize: CGFloat = FindingShareQRCode.pixelSize) -> UIImage? {
		let filter = CIFilter.qrCodeGenerator()
		filter.message = Data(url.absoluteString.utf8)
		// Medium (~15% recovery). Higher levels buy damage tolerance this code will never need — it
		// is printed into a pristine bitmap, not onto a parcel — and pay for it in modules, which is
		// the one budget that actually decides whether the card scans.
		filter.correctionLevel = "M"

		guard let output = filter.outputImage, output.extent.width >= 1, output.extent.height >= 1 else {
			return nil
		}

		// Nearest-neighbour, at a whole-number factor. The filter returns roughly one pixel per
		// module, so it *must* be enlarged; doing that with the default smoothing turns every module
		// edge into a grey ramp, which is exactly what a decoder fails on. A whole-number factor
		// keeps every module the same size as every other one — uneven module widths cost as much
		// legibility as blur does.
		let factor = max(1, (pixelSize / output.extent.width).rounded(.down))
		let scaled = output
			.samplingNearest()
			.transformed(by: CGAffineTransform(scaleX: factor, y: factor))

		// Centre the whole-number result on a white canvas of the requested size. This absorbs the
		// remainder that flooring the factor leaves over, and the white margin doubles as the quiet
		// zone the QR specification asks for around the symbol.
		let canvas = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
		let inset = ((pixelSize - scaled.extent.width) / 2).rounded(.down)
		let placed = scaled.transformed(
			by: CGAffineTransform(
				translationX: inset - scaled.extent.origin.x,
				y: inset - scaled.extent.origin.y
			)
		)
		let composed = placed
			.composited(over: CIImage(color: .white).cropped(to: canvas))
			.cropped(to: canvas)

		guard let cgImage = context.createCGImage(composed, from: canvas) else { return nil }
		return UIImage(cgImage: cgImage)
	}
}

// MARK: - The badge on the card

/// The address-and-code sticker overlaid on the card's image slot.
///
/// **Fixed black-on-white in both themes.** A QR is read by contrast alone, so letting it follow the
/// card's Light/Dark choice would print a code no scanner can see on every dark card.
///
/// It sits in the **bottom-right of the metadata block**, laid out beside the text rather than over
/// it (see `FindingShareCard.metadata`). The comment this replaces said it sat over the image slot
/// and quoted 340×246 slots from a card size that changed in AIA-0650 — neither has been true for
/// two tickets, and a comment describing a layout the code does not have is worse than none.
///
/// ## Its width is the code's width, on purpose
/// The caption used to be `.fixedSize()`, which made the badge as wide as 21 characters of text
/// rather than as wide as the code — and the badge's width is what the metadata block has to
/// reserve. Bounding it to `pointSize` and letting it scale down keeps that reservation honest.
struct FindingShareLinkBadge: View {
	let link: FindingShareCardLink

	/// The badge's full width: the code, plus the padding around it. Published so the card can
	/// reserve exactly this much and no more, rather than guessing.
	static var width: CGFloat { FindingShareQRCode.pointSize + padding * 2 }

	private static let padding: CGFloat = 5

	var body: some View {
		VStack(spacing: 3) {
			if let qrCode = link.qrCode {
				Image(uiImage: qrCode)
					.resizable()
					// Nearest-neighbour again on the way out: SwiftUI's default smoothing would undo
					// the crisp module edges the generator just went to some trouble to produce.
					.interpolation(.none)
					.frame(width: FindingShareQRCode.pointSize, height: FindingShareQRCode.pointSize)
			}
			// The brand address, not localizable — and not a `LocalizedStringKey` lookup. This is the
			// card's floor: when the compact link will not fit and there is no code, this line is the
			// only thing telling a reader where the finding came from, so it must not truncate.
			Text(verbatim: link.address)
				.font(.system(size: 8, weight: .semibold))
				.lineLimit(1)
				.minimumScaleFactor(0.7)
				.frame(width: FindingShareQRCode.pointSize)
		}
		.foregroundStyle(.black)
		.padding(Self.padding)
		.background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}
}
