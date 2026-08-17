//
//  FindingShareCard.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 13.06.26.
//

import SwiftUI

/// Orientation of the shareable card. Portrait suits Instagram/feed posts (4:5);
/// landscape suits link cards on Facebook / X (~1.9:1).
enum ShareCardOrientation: String, CaseIterable, Identifiable {
	case portrait
	case landscape

	var id: String { rawValue }

	/// Layout size in points. Rendered at the display scale (≥3) for a crisp,
	/// social-ready PNG.
	var size: CGSize {
		switch self {
		case .portrait: return CGSize(width: 340, height: 425)
		case .landscape: return CGSize(width: 460, height: 242)
		}
	}

	/// The image area within the card (the rest is the metadata block).
	var imageSlotSize: CGSize {
		switch self {
		case .portrait: return CGSize(width: size.width, height: size.height * 0.58)
		case .landscape: return CGSize(width: size.width * 0.56, height: size.height)
		}
	}
}

/// A Sendable value snapshot of a finding for sharing — built on the MainActor so
/// the composer/card never touch Core Data (and never cross the sheet boundary
/// with a managed object). Identifiable so it can drive `.sheet(item:)`.
struct FindingShareSubject: Identifiable {
	let id: UUID
	let image: UIImage?
	let normalizedBox: CGRect
	let title: String
	let label: String?
	let note: String?
	/// The finder's credit, nil when it was left blank. Rendered as a byline only when present —
	/// a shared card never invents an "Unknown" author (AIA-0651).
	let author: String?
	let gps: String?
	let detectionClass: String?
	let confidence: Double
	let host: String?
	let date: Date?
	let page: URL?

	@MainActor init(_ finding: Finding) {
		id = finding.entityId
		image = FindingScreenshotStore.load(filename: finding.screenshotFilename)
		normalizedBox = finding.normalizedBox
		title = finding.displayTitle
		label = finding.label_
		note = finding.note_
		author = finding.author
		gps = finding.gps_
		detectionClass = finding.detectionClass
		confidence = finding.detectionConfidence
		host = finding.page?.host
		date = finding.creationDate_
		page = finding.page
	}

	/// The value-level initializer. The Core Data one above is how the app builds a subject; this is
	/// how a test or a preview builds one without a managed object context, which is what makes the
	/// subject → link-payload mapping checkable on its own (AIA-0650).
	init(
		id: UUID,
		image: UIImage? = nil,
		normalizedBox: CGRect = .zero,
		title: String,
		label: String? = nil,
		note: String? = nil,
		author: String? = nil,
		gps: String? = nil,
		detectionClass: String? = nil,
		confidence: Double = 0,
		host: String? = nil,
		date: Date? = nil,
		page: URL? = nil
	) {
		self.id = id
		self.image = image
		self.normalizedBox = normalizedBox
		self.title = title
		self.label = label
		self.note = note
		self.author = author
		self.gps = gps
		self.detectionClass = detectionClass
		self.confidence = confidence
		self.host = host
		self.date = date
		self.page = page
	}
}

/// The composed, shareable card. Themed via the ambient color scheme (set
/// explicitly by the renderer, since `ImageRenderer` ignores the environment)
/// and laid out per orientation. Fixed size so the rendered pixel size is
/// deterministic and social-ready.
struct FindingShareCard: View {
	let subject: FindingShareSubject
	let orientation: ShareCardOrientation
	/// Composer-driven framing of the cover-filled image (1 = fit-to-fill).
	var zoom: CGFloat = 1
	var offset: CGSize = .zero
	/// The address + QR sticker, or `nil` (AIA-0650).
	///
	/// `nil` is the feature-flag-off path and must render **nothing**: with `isFindingShareLinkEnabled`
	/// off, the card this produces is byte-identical to the one the app shipped before the link
	/// existed. It is also the toggle-off path, and the "no compact link could be built" path.
	var link: FindingShareCardLink?

	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		Group {
			switch orientation {
			case .portrait:
				VStack(spacing: 0) {
					imageSlot
					metadata
				}
			case .landscape:
				HStack(spacing: 0) {
					imageSlot
					metadata
				}
			}
		}
		.frame(width: orientation.size.width, height: orientation.size.height)
		.background(background)
	}

	// MARK: - Pieces

	private var imageSlot: some View {
		let slot = orientation.imageSlotSize
		return ZStack(alignment: .topTrailing) {
			if let image = subject.image {
				// Cover-fill (image always fills the slot — no letterbox), then the
				// composer's zoom/pan frames it. The highlight transforms with it.
				let cover = slot.coverSize(for: image.size)
				let rect = subject.normalizedBox.visionRect(in: cover)
				ZStack {
					Image(uiImage: image)
						.resizable()
						.frame(width: cover.width, height: cover.height)
					Rectangle()
						.stroke(.red, lineWidth: 2 / zoom)
						.frame(width: rect.width, height: rect.height)
						.position(x: rect.midX, y: rect.midY)
				}
				.frame(width: cover.width, height: cover.height)
				.scaleEffect(zoom)
				.offset(offset)
				.frame(width: slot.width, height: slot.height)
				.clipped()
			} else {
				Color.black.opacity(colorScheme == .dark ? 0.35 : 0.06)
				Image(systemName: "photo")
					.font(.largeTitle)
					.foregroundStyle(.secondary)
			}
			// App icon + name so viewers can tell where the finding was captured.
			if let icon = Bundle.main.appIcon {
				VStack(spacing: 4) {
					Image(uiImage: icon)
						.resizable()
						.scaledToFill()
						.frame(width: 40, height: 40)
						.clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
						.overlay(
							RoundedRectangle(cornerRadius: 9, style: .continuous)
								.strokeBorder(.white.opacity(0.7), lineWidth: 1)
						)
					// The app's own name (brand, not localized) from the bundle.
					Text(verbatim: Bundle.main.appName)
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.white)
				}
				.shadow(radius: 3, y: 1)
				.padding(10)
			}
		}
		.frame(width: slot.width, height: slot.height)
		.clipped()
		// Bottom-trailing, opposite the app badge, and inside the slot in both orientations: the
		// metadata block is already full at these card sizes, so a 64pt code placed there would push
		// its last rows off the card.
		.overlay(alignment: .bottomTrailing) {
			if let link {
				FindingShareLinkBadge(link: link)
					.padding(10)
			}
		}
	}

	private var metadata: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(subject.title)
				.font(.title3.bold())
				.foregroundStyle(.primary)
				.lineLimit(2)

			if let detectionClass = subject.detectionClass {
				// verbatim: model class vocabulary, not localizable.
				Text(verbatim: "\(detectionClass) · \(Int(subject.confidence * 100))%")
					.font(.caption.weight(.semibold))
					.padding(.horizontal, 10)
					.padding(.vertical, 4)
					.background(Color.accentColor.opacity(0.18), in: Capsule())
					.foregroundStyle(Color.accentColor)
			}

			// The byline sits directly under the detection chip: it credits the finding as a whole,
			// so it reads above the per-field rows rather than among them (AIA-0651).
			if let author = subject.author {
				Label(author, systemImage: "person")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}

			if let label = subject.label {
				Label(label, systemImage: "tag")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			if let note = subject.note {
				Label {
					Text(note)
				} icon: {
					Image(systemName: "note.text")
				}
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(orientation == .landscape ? 2 : 4)
			}
			if let gps = subject.gps {
				Label(gps, systemImage: "location")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}

			if let host = subject.host {
				Label(host, systemImage: "globe")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			if let date = subject.date {
				Label {
					Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
				} icon: {
					Image(systemName: "calendar")
				}
				.font(.caption)
				.foregroundStyle(.secondary)
			}

			Spacer(minLength: 0)
		}
		.padding(16)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	private var background: some View {
		Color(.systemBackground)
	}
}

// MARK: - Composer

/// Pre-share options sheet: a live preview of the card with Light/Dark and
/// Portrait/Landscape toggles, then renders the chosen variant to a PNG and
/// hands it to the system share sheet — with, when `isFindingShareLinkEnabled`
/// is on and the user has not opted out, a link to the finding beside it.
struct FindingShareComposer: View {
	let subject: FindingShareSubject

	@Environment(\.dismiss) private var dismiss
	@Environment(\.displayScale) private var displayScale
	@Environment(\.colorScheme) private var systemColorScheme

	/// Observed directly rather than reached through `AppState`: a nested `ObservableObject` does not
	/// republish through its parent, so a dashboard flip would leave this sheet stale (AIA-0350).
	/// This flag is read live on purpose — it shows and hides an entry point inside a sheet, so it can
	/// be switched on the moment `link.aiarcheology.com` is verified, without waiting for cold starts.
	@EnvironmentObject private var featureFlags: FeatureFlagsState

	@State private var theme: ColorScheme = .light
	@State private var orientation: ShareCardOrientation = .portrait
	@State private var sharePayload: ActivitySharePayload?
	@State private var didSeedTheme = false

	/// **Default on, and deliberately not persisted.**
	///
	/// `theme` and `orientation` already reseed per presentation for the same reason
	/// (`didSeedTheme`). A remembered "off" would be indistinguishable from the feature never having
	/// existed: the user would turn it off once to reach Save Image, and every share they ever made
	/// afterwards would silently be an image with no way back into the app.
	@State private var includesLink = true

	/// The rendered address + QR, built once per presentation. Held in state rather than computed in
	/// `body` because the preview re-renders on every frame of a pinch or a drag, and generating a QR
	/// is a Core Image round trip.
	@State private var linkArt: FindingShareCardLink?

	// Composer-driven framing of the card image (cover-fill at zoom 1).
	@State private var imageZoom: CGFloat = 1
	@State private var imageOffset: CGSize = .zero
	@GestureState private var pinch: CGFloat = 1
	@GestureState private var dragDelta: CGSize = .zero

	private static let zoomRange: ClosedRange<CGFloat> = 1...8

	var body: some View {
		NavigationStack {
			VStack(spacing: 20) {
				preview
				controls
			}
			.padding()
			.frame(maxHeight: .infinity, alignment: .top)
			.navigationTitle(L10n.Finding.Share.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button(L10n.Common.cancel) { dismiss() }
						.tint(.blue)
						.testability(Testability.Button.findingShareCancel)
				}
				ToolbarItem(placement: .navigationBarTrailing) {
					Button(action: share) {
						Text(L10n.Common.share).bold()
					}
					.tint(.green)
					.testability(Testability.Button.findingShareConfirm)
				}
			}
			.activityShareSheet($sharePayload)
		}
		.onAppear {
			// Default to the system appearance the first time only.
			if didSeedTheme.not {
				theme = systemColorScheme
				didSeedTheme = true
			}
		}
		// `initial: true` covers the ordinary case (the flag is already on when the sheet opens);
		// the change branch covers a mid-session flip, which is the point of reading this flag live.
		.onChange(of: isLinkEnabled, initial: true) { _, enabled in
			guard enabled, linkArt == nil else { return }
			linkArt = FindingShareQRCode.cardLink(for: subject)
		}
	}

	/// The live flag. Everything this feature adds — the toggle, the card art and the shared link —
	/// hangs off this one read; with it false the composer behaves exactly as it did before AIA-0650.
	private var isLinkEnabled: Bool {
		featureFlags.snapshot.isFindingShareLinkEnabled
	}

	/// The art to print on the card, or `nil` for "print nothing".
	private var cardLink: FindingShareCardLink? {
		guard isLinkEnabled, includesLink else { return nil }
		return linkArt
	}

	private var preview: some View {
		GeometryReader { geometry in
			let fitScale = min(1, geometry.size.width / orientation.size.width)
			let liveZoom = clampZoom(imageZoom * pinch)
			let liveOffset = clampedOffset(
				CGSize(width: imageOffset.width + dragDelta.width / fitScale,
				       height: imageOffset.height + dragDelta.height / fitScale),
				zoom: liveZoom
			)
			FindingShareCard(
				subject: subject,
				orientation: orientation,
				zoom: liveZoom,
				offset: liveOffset,
				link: cardLink
			)
				.environment(\.colorScheme, theme)
				.clipShape(RoundedRectangle(cornerRadius: 16))
				.overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
				.shadow(radius: 8, y: 4)
				.scaleEffect(fitScale)
				.frame(width: geometry.size.width, height: orientation.size.height * fitScale)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.gesture(
					SimultaneousGesture(
						MagnificationGesture()
							.updating($pinch) { value, state, _ in state = value }
							.onEnded { value in
								imageZoom = clampZoom(imageZoom * value)
								imageOffset = clampedOffset(imageOffset, zoom: imageZoom)
							},
						DragGesture()
							.updating($dragDelta) { value, state, _ in state = value.translation }
							.onEnded { value in
								imageOffset = clampedOffset(
									CGSize(width: imageOffset.width + value.translation.width / fitScale,
									       height: imageOffset.height + value.translation.height / fitScale),
									zoom: imageZoom
								)
							}
					)
				)
				.onTapGesture(count: 2) {
					imageZoom = 1
					imageOffset = .zero
				}
		}
	}

	private var controls: some View {
		VStack(spacing: 16) {
			HStack(spacing: 12) {
				Image(systemName: "plus.magnifyingglass")
					.foregroundStyle(.secondary)
				Slider(value: $imageZoom, in: Self.zoomRange)
					.testability(Testability.Slider.findingShareZoom)
			}

			Picker(L10n.Finding.Share.theme, selection: $theme) {
				Text(L10n.Finding.Share.light).tag(ColorScheme.light)
				Text(L10n.Finding.Share.dark).tag(ColorScheme.dark)
			}
			.pickerStyle(.segmented)
			.testability(Testability.Picker.findingShareTheme)

			Picker(L10n.Finding.Share.layout, selection: $orientation) {
				Text(L10n.Finding.Share.portrait).tag(ShareCardOrientation.portrait)
				Text(L10n.Finding.Share.landscape).tag(ShareCardOrientation.landscape)
			}
			.pickerStyle(.segmented)
			.testability(Testability.Picker.findingShareLayout)

			// Labelled by its consequence, not its mechanism: nothing on screen tells the user what
			// "include a link" would change, and the trade-off it makes is invisible until the system
			// sheet is already up and Save Image is missing from it. Hidden entirely when the feature
			// is off, so a dark flag leaves the composer exactly as it was.
			if isLinkEnabled {
				VStack(alignment: .leading, spacing: 6) {
					Toggle(L10n.Finding.Share.includeLink, isOn: $includesLink)
						.testability(Testability.Toggle.findingShareIncludeLink)
					Text(L10n.Finding.Share.includeLinkFootnote)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
		}
		// Re-clamp when zooming out via the slider; reset framing per orientation.
		.onChange(of: imageZoom) { _, newZoom in
			imageOffset = clampedOffset(imageOffset, zoom: newZoom)
		}
		.onChange(of: orientation) { _, _ in
			imageZoom = 1
			imageOffset = .zero
		}
	}

	private func clampZoom(_ value: CGFloat) -> CGFloat {
		min(max(Self.zoomRange.lowerBound, value), Self.zoomRange.upperBound)
	}

	/// Clamps the pan so the cover-filled, zoomed image never reveals an edge.
	private func clampedOffset(_ raw: CGSize, zoom: CGFloat) -> CGSize {
		guard let image = subject.image else { return .zero }
		let slot = orientation.imageSlotSize
		let cover = slot.coverSize(for: image.size)
		let maxX = max(0, (cover.width * zoom - slot.width) / 2)
		let maxY = max(0, (cover.height * zoom - slot.height) / 2)
		return CGSize(
			width: min(max(-maxX, raw.width), maxX),
			height: min(max(-maxY, raw.height), maxY)
		)
	}

	private func share() {
		let card = FindingShareCard(
			subject: subject,
			orientation: orientation,
			zoom: clampZoom(imageZoom),
			offset: clampedOffset(imageOffset, zoom: clampZoom(imageZoom)),
			link: cardLink
		)
		.environment(\.colorScheme, theme)
		// Render at ≥3x for a crisp, social-ready PNG regardless of device scale.
		DefaultRenderer().render(card, scale: max(displayScale, 3)) { image, _ in
			guard let image else {
				LoggingPolicy.warning("Share card render failed; nothing to share", logger: .storage)
				return
			}
			// A link CAN ride along, and since AIA-0650 it does — but only as a `String`, never as a
			// `URL`. A `URL` item would make LinkPresentation fetch that address from this device to
			// build the sheet's header, an unasked-for network request behind a purely local action,
			// and would switch the sheet to link-preview presentation, hiding the image. The honest
			// cost of attaching it at all — Save Image and image-only extensions leave the sheet,
			// because an activity must accept every item — is what the toggle above gives back.
			// `FindingShareActivity.items` carries the full reasoning, including why a
			// `UIActivityItemSource` cannot dodge any of it.
			sharePayload = ActivitySharePayload(
				items: FindingShareActivity.items(
					image: image,
					subject: subject,
					isLinkEnabled: isLinkEnabled,
					includesLink: includesLink
				)
			)
		}
	}
}

extension Bundle {
	/// The app's display name (`PRODUCT_NAME` → `CFBundleDisplayName`/`CFBundleName`),
	/// so the brand is sourced from one place and follows any rename.
	var appName: String {
		(object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
			?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
			?? "ML Browser"
	}

	/// The app's own icon, resolved from the compiled `CFBundleIcons` entry.
	/// `UIImage(named: "AppIcon")` does not reliably return the asset-catalog app
	/// icon, so the icon filename is read from the bundle instead.
	var appIcon: UIImage? {
		guard
			let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
			let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
			let files = primary["CFBundleIconFiles"] as? [String],
			let lastIcon = files.last
		else { return nil }
		return UIImage(named: lastIcon)
	}
}
