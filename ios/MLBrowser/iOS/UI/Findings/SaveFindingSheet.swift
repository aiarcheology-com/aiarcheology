//
//  SaveFindingSheet.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//

import SwiftUI
import CoreData

/// Everything captured at the moment the user marked a finding: the observation
/// (a tapped detection, or a synthetic one built around a manual pick), the
/// producing driver's params (nil for manual picks), the displayed frame
/// (snapshot + results, frame-coherent by construction) and the page URL.
struct FindingCapture: Identifiable {
	let observation: DetectedObject
	let params: DeepDriverParams?
	let frame: AppliedDetectionFrame
	let pageURL: URL?

	var id: UUID { observation.uuid }

	/// The displayed detection whose box contains the tap — the smallest one wins
	/// when boxes nest, and every box counts as at least 44pt so small detections
	/// stay pickable. nil when the tap lands outside all boxes.
	static func detection(
		at location: CGPoint,
		in size: CGSize,
		results: [DetectionResult],
		minimumTarget: CGFloat = 44
	) -> (observation: DetectedObject, params: DeepDriverParams)? {
		var best: (observation: DetectedObject, params: DeepDriverParams, area: CGFloat)?
		for group in results {
			for observation in group.observations {
				let rect = observation.boundingBox.visionRect(in: size)
				let target = rect.insetBy(
					dx: min(0, (rect.width - minimumTarget) / 2),
					dy: min(0, (rect.height - minimumTarget) / 2)
				)
				guard target.contains(location) else { continue }
				let area = rect.width * rect.height
				if area < (best?.area ?? .infinity) {
					best = (observation, group.params, area)
				}
			}
		}
		return best.map { ($0.observation, $0.params) }
	}

	/// The visible window of the crop editor as a normalized TOP-LEFT rect of the
	/// image. The image is aspect-FILLED to `cover` (so it covers the `fitted`
	/// viewport with no letterbox), then zoomed by `scale` and panned by `offset`
	/// (view points). The window is what the viewport shows — its aspect matches
	/// the viewport, so saving it is WYSIWYG. Each axis is independent because the
	/// covered image overflows the viewport on one axis even at scale 1.
	static func cropRect(scale: CGFloat, offset: CGSize, fitted: CGSize, cover: CGSize) -> CGRect {
		guard fitted.width > 0, fitted.height > 0, cover.width > 0, cover.height > 0 else {
			return CGRect(x: 0, y: 0, width: 1, height: 1)
		}
		let scaledWidth = cover.width * scale
		let scaledHeight = cover.height * scale
		let windowWidth = min(1, fitted.width / scaledWidth)
		let windowHeight = min(1, fitted.height / scaledHeight)
		// A positive offset moves the image right/down — the window left/up.
		let centerX = 0.5 - offset.width / scaledWidth
		let centerY = 0.5 - offset.height / scaledHeight
		return CGRect(
			x: min(max(0, centerX - windowWidth / 2), 1 - windowWidth),
			y: min(max(0, centerY - windowHeight / 2), 1 - windowHeight),
			width: windowWidth,
			height: windowHeight
		)
	}

	/// The scale and offset that open the crop editor centred on `box`, showing `contextScale` times
	/// its size (AIA-0757).
	///
	/// Pure, and beside ``cropRect(scale:offset:fitted:cover:)`` rather than inside the editor view,
	/// so the geometry can be tested directly — the editor itself only latches and applies it.
	///
	/// Best-effort by construction: the image is aspect-**filled**, so part of it is already outside
	/// the viewport at scale 1, and a detection bigger than the largest achievable window cannot be
	/// contained at any zoom. The result is then clamped as close as the geometry permits rather than
	/// revealing an edge. A degenerate box or viewport returns "no framing" — scale 1, no offset.
	static func initialFraming(
		box visionBox: CGRect,
		cover: CGSize,
		fitted: CGSize,
		contextScale: CGFloat,
		zoomRange: ClosedRange<CGFloat>
	) -> (scale: CGFloat, offset: CGSize) {
		let unframed = (scale: zoomRange.lowerBound, offset: CGSize.zero)
		guard
			fitted.width > 0, fitted.height > 0,
			cover.width > 0, cover.height > 0,
			contextScale > 0,
			visionBox.width > 0, visionBox.height > 0
		else { return unframed }

		let target = visionBox.visionRect(in: cover)
		guard target.width > 0, target.height > 0 else { return unframed }

		// The visible window is `fitted / scale` in cover points. Ask for it to be at least
		// `contextScale` boxes wide *and* tall; whichever constraint binds wins.
		let byWidth = fitted.width / (contextScale * target.width)
		let byHeight = fitted.height / (contextScale * target.height)
		let proposed = min(byWidth, byHeight)
		guard proposed.isFinite else { return unframed }
		let scale = min(max(zoomRange.lowerBound, proposed), zoomRange.upperBound)

		// Invert `cropRect`'s centre: a positive offset moves the image right/down, so centring the
		// window on the box means offsetting by the box's distance from the middle.
		let centred = CGSize(
			width: (cover.width / 2 - target.midX) * scale,
			height: (cover.height / 2 - target.midY) * scale
		)
		// Same clamp the editor applies, so the published crop can never reveal an edge.
		let maxX = max(0, (cover.width * scale - fitted.width) / 2)
		let maxY = max(0, (cover.height * scale - fitted.height) / 2)
		return (
			scale: scale,
			offset: CGSize(
				width: min(max(-maxX, centred.width), maxX),
				height: min(max(-maxY, centred.height), maxY)
			)
		)
	}

	/// Re-normalizes a Vision box (bottom-left origin) into the crop's own
	/// coordinate space. A box fully outside the crop falls back to the whole
	/// crop — the crop IS the finding then; an empty stored box would fail
	/// validation and a fabricated location would lie.
	static func remappedBox(_ visionBox: CGRect, into cropRect: CGRect) -> CGRect {
		let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
		guard cropRect != fullRect else { return visionBox }
		guard
			cropRect.minX.isFinite,
			cropRect.minY.isFinite,
			cropRect.width.isFinite,
			cropRect.height.isFinite,
			cropRect.width > 0,
			cropRect.height > 0,
			visionBox.minX.isFinite,
			visionBox.minY.isFinite,
			visionBox.width.isFinite,
			visionBox.height.isFinite,
			visionBox.width > 0,
			visionBox.height > 0
		else { return fullRect }

		// Vision → top-left, intersect, re-normalize, → back to Vision.
		let topLeftBox = CGRect(x: visionBox.minX, y: 1 - visionBox.maxY, width: visionBox.width, height: visionBox.height)
		let visible = topLeftBox.intersection(cropRect)
		guard visible.width > 0, visible.height > 0 else { return fullRect }

		// Normalize both endpoints, not an origin plus independently divided size. The latter can
		// leave a one-ulp overflow at a crop edge, which strict persistence validation rejects.
		let relativeMinX = (visible.minX - cropRect.minX) / cropRect.width
		let relativeMinY = (visible.minY - cropRect.minY) / cropRect.height
		let relativeMaxX = (visible.maxX - cropRect.minX) / cropRect.width
		let relativeMaxY = (visible.maxY - cropRect.minY) / cropRect.height
		let normalizedValues = [relativeMinX, relativeMinY, relativeMaxX, relativeMaxY]
		guard normalizedValues.allSatisfy(\.isFinite) else { return fullRect }

		let minX = min(max(0, relativeMinX), 1)
		let minY = min(max(0, relativeMinY), 1)
		let maxX = min(max(0, relativeMaxX), 1)
		let maxY = min(max(0, relativeMaxY), 1)
		guard maxX > minX, maxY > minY else { return fullRect }

		let remapped = CGRect(
			x: minX,
			y: 1 - maxY,
			width: min(maxX - minX, 1 - minX),
			height: min(maxY - minY, 1 - minY)
		)
		let remappedValues = [remapped.minX, remapped.minY, remapped.width, remapped.height]
		guard
			remappedValues.allSatisfy(\.isFinite),
			remapped.width > 0,
			remapped.height > 0,
			remapped.minX >= 0,
			remapped.minY >= 0,
			remapped.maxX <= 1,
			remapped.maxY <= 1
		else { return fullRect }
		return remapped
	}

	/// A Vision-normalized box centered on a manual tap (top-left view
	/// coordinates), clamped fully inside the unit rect so validation holds.
	/// The view and the snapshot share the same aspect, so view-normalized
	/// coordinates are snapshot-normalized coordinates.
	static func manualBox(at location: CGPoint, in size: CGSize, side: CGFloat = 64) -> CGRect {
		guard size.width > 0, size.height > 0 else {
			return CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
		}
		let width = min(side / size.width, 1)
		let height = min(side / size.height, 1)
		let centerX = location.x / size.width
		// Vision's origin is bottom-left; the tap arrives top-left.
		let centerY = 1 - location.y / size.height
		return CGRect(
			x: min(max(0, centerX - width / 2), 1 - width),
			y: min(max(0, centerY - height / 2), 1 - height),
			width: width,
			height: height
		)
	}
}

/// Save dialog for a tapped detection (AIA-0215): stores the finding as a Core Data
/// row plus a clean image of the displayed snapshot — the highlight is always drawn
/// live from the stored bounding box, never baked into the image.
struct SaveFindingSheet: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.managedObjectContext) private var moc

	let capture: FindingCapture
	/// The onboarding tour (AIA-0333). The sheet hosts its own tour layer to spotlight Save (the
	/// sheet is modal above the root overlay) and signals capture start / save.
	let tour: TourState

	/// The persist transaction owner (AIA-0392): the sheet crops the image and calls one `save`
	/// intent — the Core Data + screenshot write lives here, not in the View.
	let repository: FindingRepository

	/// Rating-prompt bookkeeping (AIA-0117). A saved finding is a winning moment; the request
	/// itself is made by `WebScreen`'s `onDismiss`, once this sheet is off screen.
	let reviewPrompt: ReviewPromptCoordinator

	/// The signed-in account's display name, or nil when nobody is signed in (AIA-0651). Seeds the
	/// Author field ONCE, at capture; the sheet never re-reads it, so the credit a finding carries
	/// is the text that was on screen when it was saved.
	let defaultAuthor: String?

	/// Called after a successful save, before the sheet dismisses. Lets the presenter follow up —
	/// the sign-in offer needs to know a finding was actually written, which it cannot infer from
	/// the review prompt (that can decline for its own reasons) or from the tour (AIA-0536).
	var onSaved: () -> Void = {}

	/// Required, user-facing name shown in the inventory; Save is blocked until it
	/// is non-empty.
	@State private var title = ""
	/// Starts empty (user decision): suggestions cover both the detection's class
	/// and previously used labels.
	@State private var label = ""
	@State private var note = ""
	/// The finder's credit. Seeded from `defaultAuthor` on first appearance only — see `didPrefill`.
	@State private var author = ""
	/// Latches the one-shot author prefill. The guard cannot be `author.isEmpty`: the sheet's
	/// `onAppear` fires again on re-appearance, and an empty field then means the user deliberately
	/// cleared the name — restoring it would put a credit back that they just removed.
	@State private var didPrefill = false
	@State private var gps = ""
	@State private var suggestions: [String] = []
	@State private var saveFailed = false
	/// Preview-only: lets the user dim or hide the highlight rectangle to see
	/// what's underneath it. Not persisted — the stored highlight is always
	/// drawn live from the bounding box.
	@State private var highlightOpacity: Double = 1
	/// Crop editor state: the zoom slider serves mouse-only iPad-on-Mac users
	/// (pinch and drag also work); `cropRect` is the visible window the editor
	/// publishes — the unit rect means no crop.
	@State private var zoom: CGFloat = 1
	@State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)

	var body: some View {
		NavigationStack {
			Form {
				// Title first (AIA-0757 E2): it is the one required field — Save stays disabled until
				// it is filled — so it should not sit below a 420pt image the user has to scroll past.
				Section(L10n.Finding.title) {
					TextField(L10n.Finding.titlePlaceholder, text: $title)
						.testability(Testability.TextField.saveFindingTitle)
				}
				Section {
					preview
					opacitySlider
					zoomSlider
				}
				Section(L10n.Finding.page) {
					Text(capture.pageURL?.absoluteString ?? "")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Section(L10n.Finding.label) {
					TextField(L10n.Finding.labelPlaceholder, text: $label)
						.testability(Testability.TextField.saveFindingLabel)
					if suggestions.isEmpty.not {
						suggestionChips
					}
				}
				Section(L10n.Finding.note) {
					TextField(L10n.Finding.notePlaceholder, text: $note, axis: .vertical)
						.lineLimit(3...6)
						.testability(Testability.TextField.saveFindingNote)
				}
				Section(L10n.Finding.author) {
					TextField(L10n.Finding.authorPlaceholder, text: $author)
						.testability(Testability.TextField.saveFindingAuthor)
				}
				Section(L10n.Finding.gps) {
					TextField(L10n.Finding.gpsPlaceholder, text: $gps)
						.keyboardType(.numbersAndPunctuation)
						.testability(Testability.TextField.saveFindingGps)
				}
			}
			.navigationTitle(L10n.Finding.Save.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button(L10n.Common.cancel) {
						dismiss()
					}
					.tint(.blue)
					.testability(Testability.Button.saveFindingCancel)
				}
				ToolbarItem(placement: .navigationBarTrailing) {
					Button(action: save) {
						Text(L10n.Finding.Save.action)
							.bold()
					}
					.tint(.green)
					.disabled(trimmedTitle.isEmpty)
					.testability(Testability.Button.saveFindingSave)
					.tourTarget(.saveButton)
				}
			}
			.alert(L10n.Finding.Save.error, isPresented: $saveFailed) {
				Button(L10n.Common.ok, role: .cancel) {}
			}
			.onAppear {
				suggestions = Self.labelSuggestions(
					detectionClass: capture.observation.primaryLabelIdentifier,
					in: moc
				)
			}
		}
		// The sheet hosts its own tour layer (it's modal above the root overlay) to spotlight the
		// Save step; appearing fulfills the "tap the map" step (AIA-0333).
		.tourOverlay(tour, inSheet: true)
		.onAppear {
			tour.captureDidStart()
			// During the tour, pre-fill a title so the spotlighted Save is immediately enabled
			// (the dimmed Title field is reachable but not obvious) — AIA-0333.
			if tour.isOnSaveStep, title.isEmpty {
				title = L10n.Tour.defaultFindingTitle
			}
			// Author prefill (AIA-0651), exactly once per sheet: latch first, so a re-appearance
			// takes no branch at all and can never overwrite a field the user edited or cleared.
			if didPrefill.not {
				didPrefill = true
				if let defaultAuthor, defaultAuthor.isEmpty.not, author.isEmpty {
					author = defaultAuthor
				}
			}
		}
	}

	// MARK: - Preview

	/// The captured snapshot with the highlight drawn fresh, pannable and zoomable:
	/// the visible window becomes the stored crop (scale 1 = whole image = no crop).
	private var preview: some View {
		CropAdjustableSnapshot(
			image: capture.frame.image,
			normalizedBox: capture.observation.boundingBox,
			// Manual picks have no producing driver; red matches the detail view.
			color: capture.params?.annotationColor ?? .red,
			highlightOpacity: highlightOpacity,
			zoom: $zoom,
			cropRect: $cropRect
		)
		.frame(height: 420)
	}

	private var opacitySlider: some View {
		HStack(spacing: 12) {
			Image(systemName: "square.dashed")
				.foregroundStyle(.secondary)
			Slider(value: $highlightOpacity, in: 0...1)
				.testability(Testability.Slider.saveFindingHighlightOpacity)
		}
		.accessibilityLabel(L10n.Finding.highlightOpacity)
	}

	private var zoomSlider: some View {
		HStack(spacing: 12) {
			Image(systemName: "plus.magnifyingglass")
				.foregroundStyle(.secondary)
			Slider(value: $zoom, in: CropAdjustableSnapshot.zoomRange)
				.testability(Testability.Slider.saveFindingZoom)
		}
		.accessibilityLabel(L10n.Finding.zoom)
	}

	// MARK: - Labels

	private var suggestionChips: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				ForEach(suggestions, id: \.self) { suggestion in
					Button {
						label = suggestion
					} label: {
						Text(suggestion)
							.font(.callout)
							.padding(.horizontal, 10)
							.padding(.vertical, 4)
							.background(.quaternary, in: Capsule())
					}
					.buttonStyle(.borderless)
					.testability(Testability.Button.saveFindingSuggestion)
				}
			}
		}
	}

	/// Suggestion chips = the tapped detection's top class ∪ distinct stored user
	/// labels (the class keeps the list useful before the first save; the full label
	/// list of the observation would pollute it with low-confidence classes).
	static func labelSuggestions(detectionClass: String?, in context: NSManagedObjectContext) -> [String] {
		var result: [String] = []
		if let detectionClass, detectionClass.isEmpty.not {
			result.append(detectionClass)
		}
		for stored in Finding.distinctLabels(in: context)
		where result.contains(where: { $0.caseInsensitiveCompare(stored) == .orderedSame }).not {
			result.append(stored)
		}
		return result
	}

	// MARK: - Save

	/// Bake the editor's crop, then hand the finding to the repository — the whole persist
	/// transaction (image write → entity → lifecycle → save → rollback) lives there (AIA-0392).
	private func save() {
		let (imageToStore, boxToStore) = croppedCapture()
		do {
			try repository.save(
				capture: capture,
				image: imageToStore,
				box: boxToStore,
				metadata: FindingMetadata(title: title, label: label, note: note, author: author, gps: gps)
			)
			// Onboarding tour (AIA-0333): the finding is saved → advance the in-sheet save step
			// before dismissing, so the dismiss isn't mistaken for a cancel.
			tour.findingDidSave()
			// AIA-0117: recorded before `dismiss()`; WebScreen's onDismiss decides whether to ask.
			reviewPrompt.recordPositiveMoment(.findingSaved)
			onSaved()
			dismiss()
		} catch {
			saveFailed = true
		}
	}

	private var trimmedTitle: String {
		title.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Bakes the editor's crop at save time: the stored image IS the cropped region
	/// (still clean — no highlight baked in) and the box is re-normalized into
	/// crop space, so every downstream renderer works unchanged. Any failure
	/// falls back to the uncropped capture rather than losing the finding.
	private func croppedCapture() -> (image: UIImage, box: CGRect) {
		let box = capture.observation.boundingBox
		guard
			cropRect != CGRect(x: 0, y: 0, width: 1, height: 1),
			let cgImage = capture.frame.image.cgImage
		else { return (capture.frame.image, box) }

		// cropRect is top-left normalized — cgImage space directly.
		let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
		let pixelRect = CGRect(
			x: cropRect.minX * bounds.width,
			y: cropRect.minY * bounds.height,
			width: cropRect.width * bounds.width,
			height: cropRect.height * bounds.height
		).integral.intersection(bounds)
		guard pixelRect.width > 0, pixelRect.height > 0, let cropped = cgImage.cropping(to: pixelRect) else {
			return (capture.frame.image, box)
		}
		return (UIImage(cgImage: cropped), FindingCapture.remappedBox(box, into: cropRect))
	}
}

// MARK: - Crop editor

/// The preview as an Apple-Photos-style crop editor: the viewport stays fixed
/// (the fitted image frame) and the image scales/pans under it; the visible
/// window is the crop. Pinch + drag on touch (the trackpad pinch is translated
/// for iPad-on-Mac); the external zoom binding serves the slider for mouse-only
/// use; double-tap (or double-click) resets. The highlight transforms WITH the
/// image, so it always marks the same content.
private struct CropAdjustableSnapshot: View {
	let image: UIImage
	let normalizedBox: CGRect
	let color: Color
	let highlightOpacity: Double
	@Binding var zoom: CGFloat
	@Binding var cropRect: CGRect

	@State private var offset: CGSize = .zero
	@GestureState private var pinchFactor: CGFloat = 1
	@GestureState private var dragDelta: CGSize = .zero

	/// Latches the one-shot opening framing (AIA-0757). Without it a re-appearance — or any layout
	/// pass that re-runs the trigger — would throw away a zoom and pan the user had set by hand. The
	/// same hazard `SaveFindingSheet.didPrefill` exists for, and for the same reason: `onAppear`
	/// fires again on re-appearance.
	@State private var didFrame = false

	static let zoomRange: ClosedRange<CGFloat> = 1...8

	/// How much of the surroundings the editor opens with, as a multiple of the detection box.
	///
	/// The report asks for the form to show the rectangle rather than the whole page — users were
	/// reading the entire page as the finding. It does **not** ask for the rectangle alone: a finding
	/// cropped edge-to-edge loses the landscape that makes it recognisable, and that image is what a
	/// share card carries. Three times the box keeps the place identifiable while making it
	/// unmistakable which part is the finding.
	static let initialContextScale: CGFloat = 3

	var body: some View {
		GeometryReader { geometry in
			content(fitted: geometry.size)
		}
		.frame(maxWidth: .infinity)
	}

	@ViewBuilder
	private func content(fitted: CGSize) -> some View {
		let scale = clampZoom(zoom * pinchFactor)
		// Aspect-fill the viewport (no letterbox); the visible window is the crop.
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
		.onChange(of: zoom) { _, newZoom in
			// The slider can zoom out from under a panned image.
			offset = clampOffset(offset, scale: newZoom, cover: cover, fitted: fitted)
			publishCrop(fitted: fitted, cover: cover)
		}
		.onChange(of: offset) { _, _ in
			publishCrop(fitted: fitted, cover: cover)
		}
		.onAppear {
			frameOnDetectionIfNeeded(fitted: fitted)
			publishCrop(fitted: fitted, cover: cover)
		}
		// `onAppear` alone is not enough: it can fire inside the `GeometryReader` before a size has
		// settled, and at zero size there is nothing to frame against.
		.onChange(of: fitted) { _, newFitted in
			frameOnDetectionIfNeeded(fitted: newFitted)
		}

		// Pan only engages once zoomed in — at scale 1 a drag on the image
		// would just steal the form's scroll.
		if zoom > 1.001 {
			base.highPriorityGesture(drag(cover: cover, fitted: fitted))
		} else {
			base
		}
	}

	private func highlight(in cover: CGSize, scale: CGFloat) -> some View {
		let rect = normalizedBox.visionRect(in: cover)
		// Divided by the zoom so the stroke keeps its visual weight when scaled.
		return Rectangle()
			.stroke(color.opacity(highlightOpacity), lineWidth: 2 / scale)
			.frame(width: rect.width, height: rect.height)
			.position(x: rect.midX, y: rect.midY)
	}

	// MARK: Gestures

	private func pinch(cover: CGSize, fitted: CGSize) -> some Gesture {
		MagnificationGesture()
			.updating($pinchFactor) { value, state, _ in
				state = value
			}
			.onEnded { value in
				zoom = clampZoom(zoom * value)
				offset = clampOffset(offset, scale: zoom, cover: cover, fitted: fitted)
			}
	}

	private func drag(cover: CGSize, fitted: CGSize) -> some Gesture {
		DragGesture()
			.updating($dragDelta) { value, state, _ in
				state = value.translation
			}
			.onEnded { value in
				offset = clampOffset(
					CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
					scale: zoom,
					cover: cover,
					fitted: fitted
				)
			}
	}

	// MARK: Geometry

	private func clampZoom(_ value: CGFloat) -> CGFloat {
		min(max(Self.zoomRange.lowerBound, value), Self.zoomRange.upperBound)
	}

	/// Keeps the covered, scaled image from revealing an edge inside the viewport.
	private func clampOffset(_ value: CGSize, scale: CGFloat, cover: CGSize, fitted: CGSize) -> CGSize {
		let maxX = max(0, (cover.width * scale - fitted.width) / 2)
		let maxY = max(0, (cover.height * scale - fitted.height) / 2)
		return CGSize(
			width: min(max(-maxX, value.width), maxX),
			height: min(max(-maxY, value.height), maxY)
		)
	}

	/// Opens the editor centred on the detection, showing ``initialContextScale`` times its size.
	///
	/// Best-effort by construction. The image is aspect-**filled**, so at scale 1 part of it is
	/// already outside the viewport; a detection larger than the window can be at any allowed zoom
	/// simply cannot be contained, and `clampZoom`/`clampOffset` then leave the editor as close as
	/// the geometry permits rather than revealing an edge.
	private func frameOnDetectionIfNeeded(fitted: CGSize) {
		guard didFrame == false, fitted.width > 0, fitted.height > 0 else { return }
		let cover = fitted.coverSize(for: image.size)
		let framing = FindingCapture.initialFraming(
			box: normalizedBox,
			cover: cover,
			fitted: fitted,
			contextScale: Self.initialContextScale,
			zoomRange: Self.zoomRange
		)
		didFrame = true
		offset = framing.offset
		zoom = framing.scale
		publishCrop(fitted: fitted, cover: cover)
	}

	private func publishCrop(fitted: CGSize, cover: CGSize) {
		cropRect = FindingCapture.cropRect(scale: zoom, offset: offset, fitted: fitted, cover: cover)
	}
}
