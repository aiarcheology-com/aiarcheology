//
//  FindingShareCard.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 13.06.26.
//

import SwiftUI

/// A composed, shareable image of a single finding: the highlighted snapshot
/// over the finding's metadata. Rendered to a `UIImage` for the system share
/// sheet — never shown directly in the app. The frame is FIXED so the rendered
/// pixel size is deterministic (the pixel-sampling test depends on it), and the
/// color scheme is injected explicitly because `ImageRenderer` ignores the
/// ambient environment.
struct FindingShareCard: View {
	let image: UIImage?
	let normalizedBox: CGRect
	let title: String
	let detectionClass: String?
	let confidence: Double
	let host: String?
	let date: Date?

	static let width: CGFloat = 320
	static let imageHeight: CGFloat = 220

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			imageSlot
			VStack(alignment: .leading, spacing: 6) {
				Text(title)
					.font(.headline)
				if let detectionClass {
					// verbatim: model class vocabulary, not a localizable string.
					Text(verbatim: "\(detectionClass) (\(Int(confidence * 100))%)")
						.font(.subheadline)
						.foregroundStyle(.secondary)
				}
				if let host {
					Label(host, systemImage: "globe")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				if let date {
					Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.padding(12)
			.frame(width: Self.width, alignment: .leading)
		}
		.frame(width: Self.width)
		.background(Color(.systemBackground))
	}

	@ViewBuilder
	private var imageSlot: some View {
		ZStack {
			Color(.secondarySystemBackground)
			if let image {
				HighlightedSnapshotView(image: image, normalizedBox: normalizedBox, color: .red)
			} else {
				// Same placeholder direction as the detail view: never fail to share.
				Image(systemName: "photo")
					.font(.largeTitle)
					.foregroundStyle(.secondary)
			}
		}
		.frame(width: Self.width, height: Self.imageHeight)
		.clipped()
	}
}

extension FindingShareCard {
	/// Builds the card from a finding and renders it to share items on the
	/// MainActor: `[cardImage, page]` (page appended only when present), routed
	/// through the existing `DefaultRenderer` so the display-scale handling is
	/// shared. `scale` MUST come from the presenting view's `@Environment(\.displayScale)`.
	@MainActor
	static func shareItems(
		for finding: Finding,
		scale: CGFloat,
		colorScheme: ColorScheme,
		using renderer: DefaultRenderer = DefaultRenderer(),
		completion: @escaping @MainActor ([Any]) -> Void
	) {
		let card = FindingShareCard(
			image: FindingScreenshotStore.load(filename: finding.screenshotFilename),
			normalizedBox: finding.normalizedBox,
			title: finding.displayTitle,
			detectionClass: finding.detectionClass,
			confidence: finding.detectionConfidence,
			host: finding.page?.host,
			date: finding.creationDate_
		)
		let page = finding.page
		renderer.render(card.environment(\.colorScheme, colorScheme), scale: scale) { image, _ in
			var items: [Any] = []
			if let image { items.append(image) }
			if let page { items.append(page) }
			// Nothing to share (render failed AND no page) → don't present an empty
			// activity sheet; completion isn't called, so no payload is set.
			guard items.isEmpty.not else {
				LoggingPolicy.warning("No share content for finding: card render failed and no page URL", logger: .storage)
				return
			}
			completion(items)
		}
	}
}
