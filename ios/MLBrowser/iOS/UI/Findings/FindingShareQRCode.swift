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
	/// this is at least 192px in the exported PNG.
	static let pointSize: CGFloat = 64

	/// The render scale the composer guarantees. Used to size the generated bitmap for the pixels it
	/// will actually occupy rather than for the ~60px image the filter hands back.
	static let renderScale: CGFloat = 3

	static var pixelSize: CGFloat { pointSize * renderScale }

	/// The art for `subject`: always an address, and a code whenever the compact link fits.
	///
	/// The code carries the **compact** variant, never the full one, and that is the whole reason
	/// `FindingShareLink.Variant.compact` exists. A 900-character fragment payload forces QR byte
	/// mode and lands near a version-22 symbol — roughly 105 modules across — which at 192px is
	/// under 2px per module and simply does not survive being photographed off a screen, the only
	/// way a reposted card is ever scanned. Both variants resolve to the same finding.
	static func cardLink(for subject: FindingShareSubject) -> FindingShareCardLink {
		let compact = FindingShareLink.url(for: subject.linkPayload, variant: .compact)
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
/// It sits over the image rather than in the metadata block because the metadata block has no room:
/// the portrait card leaves it 178pt for up to seven rows, and a 64pt code would push the last of
/// them off the card. The image slot is 340×246 (portrait) or 257×242 (landscape) and already
/// carries the app badge in its opposite corner.
struct FindingShareLinkBadge: View {
	let link: FindingShareCardLink

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
			// The brand address, not localizable — and not a `LocalizedStringKey` lookup.
			Text(verbatim: link.address)
				.font(.system(size: 8, weight: .semibold))
				.lineLimit(1)
				.fixedSize()
		}
		.foregroundStyle(.black)
		.padding(5)
		.background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}
}
