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
	/// The edge the code should be drawn at, in points — derived from the symbol's own module count
	/// rather than fixed. See ``FindingShareQRCode/fittedPointSize(moduleCount:)``.
	let codePointSize: CGFloat

	init(address: String, qrCode: UIImage?, codePointSize: CGFloat = FindingShareQRCode.maximumPointSize) {
		self.address = address
		self.qrCode = qrCode
		self.codePointSize = codePointSize
	}
}

// MARK: - Generation

enum FindingShareQRCode {

	/// The **ceiling** on the code's edge, in points, for a payload at ``FindingShareLink/maximumCompactLength``.
	///
	/// Scannability is decided by pixels per module, so carrying more characters means more modules,
	/// which means each gets thinner unless the code gets physically bigger. At EC-M a 400-character
	/// payload is a version-15 symbol — 77 modules, 79 with the generator's quiet zone — and at 3×
	/// that needs 79pt to hold ``minimumPixelsPerModule``. 88 leaves a little headroom above the
	/// densest symbol the contract can produce.
	static let maximumPointSize: CGFloat = 88

	/// The floor: the fixed size the card carried before AIA-0657.
	///
	/// Chosen rather than derived, for two reasons. A code that shipped at this size for two releases
	/// is known to scan, so shrinking below it would be trading a proven property for a few points of
	/// card. And the address printed under the code has to stay readable — at 8pt it needs about
	/// 84pt, which fits here once allowed to scale to 0.7, and does not fit anything much smaller.
	///
	/// The practical effect: a typical finding's code is 64pt, exactly as before, and only a link
	/// long enough to need more modules makes it grow.
	static let minimumPointSize: CGFloat = 64

	/// Below roughly this, a code stops surviving being photographed off a screen — which is the only
	/// way a reposted card is ever scanned.
	static let minimumPixelsPerModule: CGFloat = 3

	/// The size a symbol of `moduleCount` modules (quiet zone included) must be drawn at.
	///
	/// The budget is a ceiling, not a size: a finding shared from `ags.cuzk.cz/av/` produces a link
	/// near 150 characters, which is a version-11 symbol at 61 modules and needs 63pt — while the
	/// 400-character worst case needs 79pt. Fixing every code at the worst case would spend 16pt of
	/// card on symbols that do not need it, and on a card where the badge now *reserves* its width
	/// from the text beside it, that width is the metadata block's to lose.
	static func fittedPointSize(moduleCount: CGFloat) -> CGFloat {
		let needed = (moduleCount * minimumPixelsPerModule / renderScale).rounded(.up)
		return min(maximumPointSize, max(minimumPointSize, needed))
	}

	/// The render scale the composer guarantees. Used to size the generated bitmap for the pixels it
	/// will actually occupy rather than for the ~60px image the filter hands back.
	static let renderScale: CGFloat = 3

	/// The bitmap edge for a code drawn at the ceiling. Callers that size dynamically pass their own.
	static var pixelSize: CGFloat { maximumPointSize * renderScale }

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
		guard let compact, let fitted = code(for: compact) else {
			return FindingShareCardLink(address: FindingShareLink.webHost, qrCode: nil)
		}
		return FindingShareCardLink(
			address: FindingShareLink.webHost,
			qrCode: fitted.image,
			codePointSize: fitted.pointSize
		)
	}

	/// A code sized to its own payload: the symbol is generated once, its module count read off the
	/// filter's output, and the bitmap then rendered for exactly the points that symbol needs.
	///
	/// Two passes over the same `CIImage`, not two encodes — the expensive part happens once.
	static func code(for url: URL) -> (image: UIImage, pointSize: CGFloat)? {
		guard let symbol = symbol(for: url) else { return nil }
		// `extent.width` is the module count *including* the one-module quiet zone the generator adds
		// on each side, which is the number that has to survive being photographed.
		let pointSize = fittedPointSize(moduleCount: symbol.extent.width)
		guard let image = image(from: symbol, pixelSize: pointSize * renderScale) else { return nil }
		return (image, pointSize)
	}

	/// Creating a `CIContext` sets up a GPU pipeline and is expensive, so one is reused — the same
	/// pattern as `UIImage.adjusted(brightness:contrast:saturation:)`. `CIContext` is thread-safe.
	private static let context = CIContext(options: nil)

	/// Encodes `url` and hands back the raw symbol — one module per pixel, quiet zone included.
	///
	/// Separated from the rendering below so ``code(for:)`` can read the module count *before*
	/// choosing a size. Deriving the size from the symbol is the only way to make the badge cost the
	/// card no more room than its payload actually requires.
	private static func symbol(for url: URL) -> CIImage? {
		let filter = CIFilter.qrCodeGenerator()
		filter.message = Data(url.absoluteString.utf8)
		// Medium (~15% recovery). Higher levels buy damage tolerance this code will never need — it
		// is printed into a pristine bitmap, not onto a parcel — and pay for it in modules, which is
		// the one budget that actually decides whether the card scans.
		filter.correctionLevel = "M"

		guard let output = filter.outputImage, output.extent.width >= 1, output.extent.height >= 1 else {
			return nil
		}
		return output
	}

	/// Renders `url` as a QR bitmap `pixelSize` pixels square, or `nil` if it cannot be encoded.
	static func image(for url: URL, pixelSize: CGFloat = FindingShareQRCode.pixelSize) -> UIImage? {
		guard let output = symbol(for: url) else { return nil }
		return image(from: output, pixelSize: pixelSize)
	}

	private static func image(from output: CIImage, pixelSize: CGFloat) -> UIImage? {
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

/// The address-and-code sticker in the card's metadata block.
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

	/// The widest the badge can ever be — the ceiling code plus its padding.
	///
	/// What the *layout test* reserves against, because the card must hold the worst case rather
	/// than the typical one. There is deliberately no per-instance width: the badge sizes itself
	/// from `link.codePointSize` in `body`, and a second property computing the same number invited
	/// a future reader to believe it drove the layout when nothing read it (raised in review).
	static var maximumWidth: CGFloat { FindingShareQRCode.maximumPointSize + padding * 2 }

	private static let padding: CGFloat = 5

	var body: some View {
		VStack(spacing: 3) {
			if let qrCode = link.qrCode {
				Image(uiImage: qrCode)
					.resizable()
					// Nearest-neighbour again on the way out: SwiftUI's default smoothing would undo
					// the crisp module edges the generator just went to some trouble to produce.
					.interpolation(.none)
					.frame(width: link.codePointSize, height: link.codePointSize)
			}
			// The brand address, not localizable — and not a `LocalizedStringKey` lookup. This is the
			// card's floor: when the compact link will not fit and there is no code, this line is the
			// only thing telling a reader where the finding came from, so it must not truncate.
			Text(verbatim: link.address)
				.font(.system(size: 8, weight: .semibold))
				.lineLimit(1)
				.minimumScaleFactor(0.7)
				.frame(width: link.codePointSize)
		}
		.foregroundStyle(.black)
		.padding(Self.padding)
		.background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}
}
