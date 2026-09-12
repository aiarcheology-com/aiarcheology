//
//  FindingDetailView.swift
//  AI Archeology
//
//  The stored-finding editor, lifted out of FindingsListView (AIA-0835) so the shared-link screen
//  can present a received finding in it without pulling in the whole inventory.
//
//  `InspectableHighlightedSnapshot` and `CGSize.coverSize` came across with it: both were
//  file-private to FindingsListView.swift and are used by nothing else, so leaving them behind
//  would have meant either widening their visibility or duplicating them.
//

import SwiftUI

/// One stored finding: the full snapshot with the detection highlighted live
/// (drawn from the stored bounding box — never baked into the image), the
/// editable text fields, and the way back to the captured page. Edits are
/// committed by the explicit Save button — never implicitly on navigation.
struct FindingDetailView: View {
	/// Held only to hand on to the share composer's own sheet, which needs it live (AIA-0650).
	@EnvironmentObject private var featureFlags: FeatureFlagsState
	@ObservedObject var finding: Finding
	/// Edits commit through the repository rather than straight to the context, so sync hears about
	/// them the moment they land instead of on the next unrelated trigger (AIA-737).
	let findingRepository: FindingRepository
	let onOpenPage: (URL) -> Void

	/// Whether this finding's fields may be edited.
	///
	/// Derived from the row rather than passed in: a received finding is read-only wherever it is
	/// opened, and a caller that could pass `true` would be a way to lose that (AIA-0835). The
	/// stored copy has to keep matching what the sender sent -- that is what makes the finding id a
	/// signature rather than a local identifier.
	private var isEditable: Bool { finding.source == .local }

	@State private var title = ""
	@State private var label = ""
	@State private var note = ""
	/// The finder's credit (AIA-0651). Seeded from the stored value only — never from the signed-in
	/// account: prefill is a capture-time convenience, and re-applying it here would rewrite the
	/// credit on findings captured by, or already shared with, someone else.
	@State private var author = ""
	@State private var gps = ""
	/// The page URL, editable since AIA-0817. Before that a URL the app resolved wrongly was
	/// permanent once saved, and a finding captured with no page had nowhere to gain one.
	@State private var page = ""
	@State private var saveFailed = false

	@State private var shareSubject: FindingShareSubject?

	/// Inspect-only view state for the stored snapshot — never persisted (the
	/// stored image/box are fixed; the save sheet owns crop editing).
	@State private var highlightOpacity: Double = 1
	@State private var snapshotZoom: CGFloat = 1

	var body: some View {
		List {
			// Title first, matching the save sheet (AIA-0757 E2). It is the finding's name, and the
			// name belongs above the picture in both places — reading one form and editing the other
			// should not mean hunting for the same field in a different position.
			receivedSection
			titleSection
			// Where the finding IS comes before how it looked: on a map site the page and the
			// coordinate answer the question the finding was made to answer, and they were
			// previously below the image and three text fields.
			pageSection
			gpsSection
			snapshotSection
			labelSection
			noteSection
			authorSection
			detectionSection
		}
		.navigationTitle(finding.displayTitle)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar { toolbarContent }
		.alert(L10n.Finding.Save.error, isPresented: $saveFailed) {
			Button(L10n.Common.ok, role: .cancel) {}
		}
		.sheet(item: $shareSubject) { subject in
			FindingShareComposer(subject: subject)
				// Environment objects do not reliably cross a `.sheet` boundary on Mac (Designed for
				// iPad) — re-inject, per AGENTS.md §3.
				.environmentObject(featureFlags)
		}
		.onAppear(perform: seedFields)
	}

	@ViewBuilder
	private var snapshotSection: some View {
		Section {
			if let image = FindingScreenshotStore.load(filename: finding.screenshotFilename) {
				InspectableHighlightedSnapshot(
					image: image,
					normalizedBox: finding.normalizedBox,
					color: .red,
					zoom: $snapshotZoom,
					highlightOpacity: $highlightOpacity
				)
				// Definite height: the cover layout uses a GeometryReader, which
				// collapses to nothing under a maxHeight cap inside a List row.
				.frame(height: 420)
				opacitySlider
				zoomSlider
			} else if let box = receivedBox {
				// A link carries no picture, so a received finding has a canonical screenshot name
				// with no file behind it. Rather than the generic missing-image glyph, draw the
				// framing diagram the shared-link card already shows: where the detection sat in the
				// scene. A real image is a later ticket's backend work (AIA-0835).
				//
				// The wrapper carries the accessibility label because the diagram itself is
				// `.accessibilityHidden` -- it is a picture of a rectangle and says nothing aloud.
				VStack(spacing: 8) {
					SharedFindingBoxDiagram(box: box)
					Text(L10n.Finding.Received.noImage)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
				}
				.frame(maxWidth: .infinity)
				.padding(.vertical, 16)
				.accessibilityElement(children: .ignore)
				.accessibilityLabel(L10n.Finding.Received.noImage)
			} else {
				Image(systemName: "photo")
					.font(.largeTitle)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity)
					.padding(.vertical, 32)
			}
		}
	}

	/// The wire box to draw when this finding has no image, or nil when there is nothing honest to
	/// draw.
	///
	/// Gated on `captureNormalizedBox` being non-zero, NOT on `normalizedBox`: the latter has no
	/// absence signal and a link that carried no box stores the unit rect there, which would draw a
	/// rectangle around the whole frame and claim a whole-page detection. The zero capture box is
	/// the documented "not recorded" marker (AIA-0761).
	private var receivedBox: FindingShareLink.Box? {
		guard finding.source == .received else { return nil }
		let capture = finding.captureNormalizedBox
		guard capture != .zero else { return nil }
		// Back to the wire's top-left origin, the space the diagram draws in.
		return FindingShareLink.Box(
			x: capture.minX,
			y: 1 - capture.minY - capture.height,
			width: capture.width,
			height: capture.height
		)
	}

	/// Says where this finding came from, and when it arrived.
	///
	/// A stored row looks more trustworthy than an unsaved one, so the provenance the shared-link
	/// card states has to survive into the stored view -- otherwise saving a stranger's finding is
	/// what launders it into looking like the user's own work.
	@ViewBuilder
	private var receivedSection: some View {
		if finding.source == .received {
			Section {
				Label(L10n.Finding.Received.provenance, systemImage: "person.crop.circle.badge.questionmark")
					.font(.footnote)
					.foregroundStyle(.secondary)
				if let receivedAt = finding.receivedAt {
					LabeledContent(
						L10n.Finding.Received.on,
						value: receivedAt.formatted(date: .abbreviated, time: .shortened)
					)
					.font(.footnote)
				}
			}
		}
	}

	private var titleSection: some View {
		Section(L10n.Finding.title) {
			TextField(L10n.Finding.titlePlaceholder, text: $title)
				.disabled(isEditable.not)
				.testability(Testability.TextField.findingDetailTitle)
		}
	}

	private var labelSection: some View {
		Section(L10n.Finding.label) {
			TextField(L10n.Finding.labelPlaceholder, text: $label)
				.disabled(isEditable.not)
				.testability(Testability.TextField.findingDetailLabel)
		}
	}

	private var noteSection: some View {
		Section(L10n.Finding.note) {
			TextField(L10n.Finding.notePlaceholder, text: $note, axis: .vertical)
				.lineLimit(3...6)
				.disabled(isEditable.not)
				.testability(Testability.TextField.findingDetailNote)
		}
	}

	private var authorSection: some View {
		Section(L10n.Finding.author) {
			TextField(L10n.Finding.authorPlaceholder, text: $author)
				.disabled(isEditable.not)
				.testability(Testability.TextField.findingDetailAuthor)
		}
	}

	private var gpsSection: some View {
		Section(L10n.Finding.gps) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				// The ordinary keyboard, for the reason the save sheet's copy of this field carries:
				// the value can hold letters — `leaflet: 47.9, 18.7`, `S-JTSK (EPSG:5514): …` — and a
				// numeric keyboard cannot type one of them. Fixed in the save sheet first and missed
				// here, which is exactly the kind of half-fix a second reviewer catches.
				TextField(L10n.Finding.gpsPlaceholder, text: $gps)
					.disabled(isEditable.not)
					.testability(Testability.TextField.findingDetailGps)
				copyButton(gps, identifier: Testability.Button.findingDetailCopyGps)
			}
		}
	}

	/// A visible copy button, matching the save sheet and the model download screen.
	private func copyButton(_ value: String, identifier: Testability.Button) -> some View {
		Button {
			// Plain text ONLY, not `UIPasteboard.string`.
			//
			// A stored coordinate begins `arcgis: `, `leaflet: ` … which UIKit reads as a URL
			// scheme: setting `.string` also publishes a URL flavour, and a receiving app that
			// prefers it pastes `arcgis:%2040.92…` with the spaces percent-encoded. Declaring a
			// single plain-text representation leaves nothing else for anyone to choose.
			UIPasteboard.general.setValue(value, forPasteboardType: "public.utf8-plain-text")
		} label: {
			Image(systemName: "doc.on.doc")
		}
		.accessibilityLabel(L10n.Common.copy)
		.buttonStyle(.borderless)
		.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
		.testability(identifier)
	}

	@ViewBuilder
	private var detectionSection: some View {
		if let detectionClass = finding.detectionClass {
			Section(L10n.Finding.detection) {
				// verbatim: class names are model vocabulary, not localizable —
				// and plain interpolation gets auto-extracted into the catalog.
				Text(verbatim: "\(detectionClass) (\(Int(finding.detectionConfidence * 100))%)")
					.foregroundStyle(.secondary)
			}
		}
	}

	@ViewBuilder
	private var pageSection: some View {
		// Always shown, unlike before AIA-0817: the section used to vanish when `page` was nil,
		// which is exactly the finding that most needs somewhere to put a URL.
		Section(L10n.Finding.page) {
			// `L10n.Finding.page` doubles as the prompt, so the control carries an accessibility
			// label without adding a string to all 17 locales.
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				TextField(L10n.Finding.page, text: $page, axis: .vertical)
					.disabled(isEditable.not)
					.font(.caption)
					.lineLimit(1...3)
					.keyboardType(.URL)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.testability(Testability.TextField.findingDetailPage)
				copyButton(page, identifier: Testability.Button.findingDetailCopyPage)
			}
			// Offered only for a URL that can actually be opened, so the button never appears
			// against text the user is midway through typing.
			if let openable = resolvedPage {
				Button {
					onOpenPage(openable)
				} label: {
					Label(L10n.Findings.openPage, systemImage: "safari")
				}
				.testability(Testability.Button.findingsOpenPage)
			}
		}
	}

	@ToolbarContentBuilder
	private var toolbarContent: some ToolbarContent {
		ToolbarItemGroup(placement: .navigationBarTrailing) {
			Button(action: shareFinding) {
				Label(L10n.Common.share, systemImage: "square.and.arrow.up")
			}
			.tint(.blue)
			.testability(Testability.Button.findingDetailShare)
			// Share stays available on a received finding: forwarding is not editing, and
			// `FindingShareSubject` reads `author` straight off the row, so the sender keeps the
			// credit. Save does not -- there is nothing to commit on a form that cannot change.
			if isEditable {
				Button(action: saveEdits) {
					Text(L10n.Finding.Save.action)
						.bold()
				}
				.disabled(hasChanges.not || trimmedTitle.isEmpty)
				.tint(.green)
				.testability(Testability.Button.findingDetailSave)
			}
		}
	}

	private func shareFinding() {
		shareSubject = FindingShareSubject(finding)
	}

	private var opacitySlider: some View {
		HStack(spacing: 12) {
			Image(systemName: "square.dashed")
				.foregroundStyle(.secondary)
			Slider(value: $highlightOpacity, in: 0...1)
				.testability(Testability.Slider.findingDetailHighlightOpacity)
		}
		.accessibilityLabel(L10n.Finding.highlightOpacity)
	}

	private var zoomSlider: some View {
		HStack(spacing: 12) {
			Image(systemName: "plus.magnifyingglass")
				.foregroundStyle(.secondary)
			Slider(value: $snapshotZoom, in: InspectableHighlightedSnapshot.zoomRange)
				.testability(Testability.Slider.findingDetailZoom)
		}
		.accessibilityLabel(L10n.Finding.zoom)
	}

	// MARK: - Editing

	private var hasChanges: Bool {
		trimmedTitle != finding.title
			|| normalized(label) != finding.label_
			|| normalized(note) != finding.note_
			|| normalized(author) != finding.author
			|| normalized(gps) != finding.gps_
			|| resolvedPage != finding.page
	}

	/// What saving would store for the page, given what is currently typed.
	///
	/// Shared by ``hasChanges`` and ``saveEdits`` deliberately: if the two applied different rules,
	/// an unusable edit could enable Save and then quietly store nothing.
	private var resolvedPage: URL? {
		FindingPageURL.resolve(edited: page, captured: finding.page)
	}

	private var trimmedTitle: String {
		title.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func seedFields() {
		title = finding.title
		label = finding.label_ ?? ""
		note = finding.note_ ?? ""
		author = finding.author ?? ""
		gps = finding.gps_ ?? ""
		page = finding.page?.absoluteString ?? ""
	}

	private func saveEdits() {
		finding.title = trimmedTitle
		finding.label_ = normalized(label)
		finding.note_ = normalized(note)
		finding.author = normalized(author)
		finding.gps_ = normalized(gps)
		finding.page = resolvedPage
		do {
			try findingRepository.commitEdits()
		} catch {
			LoggingPolicy.error("Failed to save finding edits", error: error, logger: .storage)
			// Reload from the store so the fields reflect the persisted state
			// instead of silently diverging from it (ConfigurationRow precedent).
			findingRepository.discardEdits(to: finding)
			seedFields()
			saveFailed = true
		}
	}

	private func normalized(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}
}

// MARK: - Inspectable snapshot

/// Read-only zoom/pan inspector for a stored snapshot, with an adjustable
/// highlight opacity. Nothing here is persisted — the stored image and box are
/// fixed (the save sheet's `CropAdjustableSnapshot` owns crop editing; this
/// shares the same pan/zoom math but publishes no crop).
struct InspectableHighlightedSnapshot: View {
	let image: UIImage
	let normalizedBox: CGRect
	let color: Color
	@Binding var zoom: CGFloat
	@Binding var highlightOpacity: Double

	@State private var offset: CGSize = .zero
	@GestureState private var pinchFactor: CGFloat = 1
	@GestureState private var dragDelta: CGSize = .zero

	static let zoomRange: ClosedRange<CGFloat> = 1...8

	var body: some View {
		GeometryReader { geometry in
			content(fitted: geometry.size)
		}
		.frame(maxWidth: .infinity)
	}

	@ViewBuilder
	private func content(fitted: CGSize) -> some View {
		let scale = clampZoom(zoom * pinchFactor)
		// Aspect-fill: the image covers the whole container (no letterbox); overflow
		// is clipped. Zoom/pan then operate on the covered image.
		let cover = fitted.coverSize(for: image.size)
		let shownOffset = clampOffset(
			CGSize(width: offset.width + dragDelta.width, height: offset.height + dragDelta.height),
			scale: scale,
			cover: cover,
			fitted: fitted
		)
		let base = ZStack {
			Image(uiImage: image)
				.resizable()
				.frame(width: cover.width, height: cover.height)
			highlight(in: cover, scale: scale)
		}
		.frame(width: cover.width, height: cover.height)
		.scaleEffect(scale)
		.offset(shownOffset)
		.frame(width: fitted.width, height: fitted.height)
		.clipped()
		.contentShape(Rectangle())
		.gesture(pinch(cover: cover, fitted: fitted))
		.onTapGesture(count: 2) {
			zoom = 1
			offset = .zero
		}

		// Pan only once zoomed in — at scale 1 a drag would just steal scrolling.
		if zoom > 1.001 {
			base.highPriorityGesture(drag(cover: cover, fitted: fitted))
		} else {
			base
		}
	}

	private func highlight(in cover: CGSize, scale: CGFloat) -> some View {
		let rect = normalizedBox.visionRect(in: cover)
		return Rectangle()
			.stroke(color.opacity(highlightOpacity), lineWidth: 2 / scale)
			.frame(width: rect.width, height: rect.height)
			.position(x: rect.midX, y: rect.midY)
	}

	private func pinch(cover: CGSize, fitted: CGSize) -> some Gesture {
		MagnificationGesture()
			.updating($pinchFactor) { value, state, _ in state = value }
			.onEnded { value in
				zoom = clampZoom(zoom * value)
				offset = clampOffset(offset, scale: zoom, cover: cover, fitted: fitted)
			}
	}

	private func drag(cover: CGSize, fitted: CGSize) -> some Gesture {
		DragGesture()
			.updating($dragDelta) { value, state, _ in state = value.translation }
			.onEnded { value in
				offset = clampOffset(
					CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
					scale: zoom,
					cover: cover,
					fitted: fitted
				)
			}
	}

	private func clampZoom(_ value: CGFloat) -> CGFloat {
		min(max(Self.zoomRange.lowerBound, value), Self.zoomRange.upperBound)
	}

	/// Keeps the scaled, covered image from revealing an edge inside the viewport.
	private func clampOffset(_ value: CGSize, scale: CGFloat, cover: CGSize, fitted: CGSize) -> CGSize {
		let maxX = max(0, (cover.width * scale - fitted.width) / 2)
		let maxY = max(0, (cover.height * scale - fitted.height) / 2)
		return CGSize(
			width: min(max(-maxX, value.width), maxX),
			height: min(max(-maxY, value.height), maxY)
		)
	}
}

// MARK: - Cover sizing

extension CGSize {
	/// The size the given image must be scaled to so it fully COVERS `self`
	/// (aspect-fill) — the larger dimension overflows and is clipped by the caller.
	func coverSize(for imageSize: CGSize) -> CGSize {
		guard imageSize.width > 0, imageSize.height > 0 else { return self }
		let scale = max(width / imageSize.width, height / imageSize.height)
		return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
	}
}
