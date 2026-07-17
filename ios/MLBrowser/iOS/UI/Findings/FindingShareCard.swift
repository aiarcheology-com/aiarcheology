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
		gps = finding.gps_
		detectionClass = finding.detectionClass
		confidence = finding.detectionConfidence
		host = finding.page?.host
		date = finding.creationDate_
		page = finding.page
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
/// hands it (plus the page URL) to the system share sheet.
struct FindingShareComposer: View {
	let subject: FindingShareSubject

	@Environment(\.dismiss) private var dismiss
	@Environment(\.displayScale) private var displayScale
	@Environment(\.colorScheme) private var systemColorScheme

	@State private var theme: ColorScheme = .light
	@State private var orientation: ShareCardOrientation = .portrait
	@State private var sharePayload: ActivitySharePayload?
	@State private var didSeedTheme = false

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
			FindingShareCard(subject: subject, orientation: orientation, zoom: liveZoom, offset: liveOffset)
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
			offset: clampedOffset(imageOffset, zoom: clampZoom(imageZoom))
		)
		.environment(\.colorScheme, theme)
		// Render at ≥3x for a crisp, social-ready PNG regardless of device scale.
		DefaultRenderer().render(card, scale: max(displayScale, 3)) { image, _ in
			// Image only: attaching the page URL as a second item makes iOS treat
			// the share as a link (link preview), which hides image actions like
			// "Save Image" / Photos / Instagram. The source host is on the card.
			guard let image else {
				LoggingPolicy.warning("Share card render failed; nothing to share", logger: .storage)
				return
			}
			sharePayload = ActivitySharePayload(items: [image])
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
