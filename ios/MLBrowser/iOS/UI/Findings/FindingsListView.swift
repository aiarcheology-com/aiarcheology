//
//  FindingsListView.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//

import SwiftUI
import CoreData

/// The findings inventory (AIA-0215): stored detections with label filtering,
/// presented as a sheet from the drawer's Findings section.
struct FindingsListView: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.managedObjectContext) private var moc
	/// Held only to hand on to the share composer's own sheet, which needs it live (AIA-0650).
	@EnvironmentObject private var featureFlags: FeatureFlagsState

	/// "Open page" routes through the presenting drawer: it must dismiss this
	/// sheet and the drawer before the web screen loads the URL.
	let onOpenPage: (URL) -> Void

	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \Finding.creationDate_, ascending: false)],
		predicate: NSPredicate(
			format: "%K == %@",
			#keyPath(Finding.lifeCycleString),
			CoreDataManageableState.ready.rawValue
		),
		animation: .default)
	private var findings: FetchedResults<Finding>

	/// nil = no filter (all findings, including unlabeled ones).
	@State private var filterLabel: String?

	/// ZIP export goes straight to the system share sheet; per-finding sharing
	/// goes through the composer (which owns its own share-sheet presentation).
	@State private var sharePayload: ActivitySharePayload?
	@State private var shareSubject: FindingShareSubject?
	@State private var isExporting = false
	@State private var exportFailed = false

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				if distinctLabels.isEmpty.not {
					filterChips
				}
				List {
					if filteredFindings.isEmpty {
						emptyStateView
					}
					ForEach(filteredFindings, id: \.objectID) { finding in
						row(finding)
					}
				}
				.listStyle(.plain)
			}
			.navigationTitle(L10n.Findings.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					exportButton
				}
				ToolbarItem(placement: .navigationBarTrailing) {
					Button(action: { dismiss() }) {
						Text(L10n.Common.dismiss)
					}
					.tint(.blue)
					.testability(Testability.Button.findingsDismiss)
				}
			}
			.navigationDestination(for: Finding.self) { finding in
				FindingDetailView(finding: finding, onOpenPage: onOpenPage)
			}
		}
		.onAppear {
			// Self-heal write-time leftovers (PNG written, entity insert failed) and
			// failed file deletes. Runs on the viewContext/MainActor; the save sheet
			// is dismissed before this list can open, so it never races a save.
			FindingScreenshotStore.sweepOrphans(in: moc)
		}
		.activityShareSheet($sharePayload)
		.sheet(item: $shareSubject) { subject in
			FindingShareComposer(subject: subject)
				// Environment objects do not reliably cross a `.sheet` boundary on Mac (Designed for
				// iPad) — re-inject, per AGENTS.md §3.
				.environmentObject(featureFlags)
		}
		.alert(L10n.Findings.Export.error, isPresented: $exportFailed) {
			Button(L10n.Common.ok, role: .cancel) {}
		}
	}

	// MARK: - Export & share

	/// Exports the CURRENTLY FILTERED findings (not the raw fetch) as a ZIP. The
	/// snapshot is taken synchronously on the MainActor at tap time; the heavy
	/// zip build runs detached so the UI stays responsive.
	@ViewBuilder
	private var exportButton: some View {
		if isExporting {
			ProgressView()
		} else {
			Button(action: exportFindings) {
				Text(L10n.Findings.export)
					.bold()
			}
			.tint(.green)
			.disabled(filteredFindings.isEmpty)
			.testability(Testability.Button.findingsExport)
		}
	}

	private func exportFindings() {
		let snapshots = filteredFindings.map(FindingSnapshot.init)
		isExporting = true
		Task {
			do {
				let url = try await Task.detached(priority: .userInitiated) {
					try FindingExporter.makeZip(from: snapshots)
				}.value
				sharePayload = ActivitySharePayload(items: [url])
			} catch {
				LoggingPolicy.error("Failed to export findings", error: error, logger: .storage)
				exportFailed = true
			}
			isExporting = false
		}
	}

	private func share(_ finding: Finding) {
		shareSubject = FindingShareSubject(finding)
	}

	// MARK: - Filtering

	private var distinctLabels: [String] {
		Finding.distinctLabels(in: moc)
	}

	private var filteredFindings: [Finding] {
		guard let filterLabel else { return Array(findings) }
		// Case-insensitive, matching the chips' identity (distinctLabels).
		return findings.filter { $0.label_?.caseInsensitiveCompare(filterLabel) == .orderedSame }
	}

	private var filterChips: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				chip(title: L10n.Findings.Filter.all, isSelected: filterLabel.isNil) {
					filterLabel = nil
				}
				ForEach(distinctLabels, id: \.self) { label in
					chip(title: label, isSelected: filterLabel == label) {
						filterLabel = label
					}
				}
			}
			.padding(.horizontal)
			.padding(.vertical, 8)
		}
	}

	private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Text(title)
				.font(.callout)
				.padding(.horizontal, 12)
				.padding(.vertical, 5)
				.background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
				.foregroundStyle(isSelected ? .white : .primary)
		}
		.buttonStyle(.borderless)
		.testability(Testability.Button.findingsFilterLabel, label: title)
	}

	// MARK: - Rows

	private func row(_ finding: Finding) -> some View {
		NavigationLink(value: finding) {
			HStack(spacing: 12) {
				thumbnail(finding)
				VStack(alignment: .leading, spacing: 2) {
					Text(finding.displayTitle)
						.foregroundStyle(.primary)
					if let page = finding.page, let host = page.host {
						Text(host)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					if let date = finding.creationDate_ {
						Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		.testability(Testability.Button.findingsItem)
		.swipeActions(edge: .trailing, allowsFullSwipe: true) {
			Button(role: .destructive) {
				delete(finding)
			} label: {
				Label(L10n.Common.delete, systemImage: "trash")
			}
			.testability(Testability.Button.findingsDeleteEntry)
		}
		.swipeActions(edge: .leading) {
			Button {
				share(finding)
			} label: {
				Label(L10n.Common.share, systemImage: "square.and.arrow.up")
			}
			.tint(.blue)
			.testability(Testability.Button.findingsShareEntry)
		}
		// Right-click is the Mac idiom; on touch the leading swipe is the share
		// affordance, so the context menu is Mac-only.
		.macContextMenu {
			Button {
				share(finding)
			} label: {
				Label(L10n.Common.share, systemImage: "square.and.arrow.up")
			}
		}
	}

	@ViewBuilder
	private func thumbnail(_ finding: Finding) -> some View {
		if let image = finding.cropThumbnail() {
			Image(uiImage: image)
				.resizable()
				.scaledToFill()
				.frame(width: 56, height: 56)
				.clipShape(RoundedRectangle(cornerRadius: 8))
		} else {
			// Row whose file is missing: placeholder, never auto-deleted (the
			// orphan sweep only removes files WITHOUT rows).
			Image(systemName: "photo")
				.foregroundStyle(.secondary)
				.frame(width: 56, height: 56)
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
		}
	}

	private var emptyStateView: some View {
		VStack(spacing: 12) {
			Image(systemName: "archivebox")
				.font(.largeTitle)
				.foregroundStyle(.secondary)
			Text(L10n.Findings.Empty.title)
				.font(.headline)
			Text(L10n.Findings.Empty.message)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 32)
	}

	/// Entity first (committed), then best-effort file delete: a leftover file is
	/// exactly the direction the orphan sweep self-heals. The filename is captured
	/// before deletion — Core Data nullifies attributes on delete.
	private func delete(_ finding: Finding) {
		let filename = finding.screenshotFilename
		moc.delete(finding)
		do {
			try Finding.save(in: moc)
		} catch {
			LoggingPolicy.error("Failed to delete the finding", error: error, logger: .storage)
			return
		}
		FindingScreenshotStore.delete(filename: filename)
	}
}

// MARK: - Detail

/// One stored finding: the full snapshot with the detection highlighted live
/// (drawn from the stored bounding box — never baked into the image), the
/// editable text fields, and the way back to the captured page. Edits are
/// committed by the explicit Save button — never implicitly on navigation.
private struct FindingDetailView: View {
	@Environment(\.managedObjectContext) private var moc
	/// Held only to hand on to the share composer's own sheet, which needs it live (AIA-0650).
	@EnvironmentObject private var featureFlags: FeatureFlagsState
	@ObservedObject var finding: Finding
	let onOpenPage: (URL) -> Void

	@State private var title = ""
	@State private var label = ""
	@State private var note = ""
	/// The finder's credit (AIA-0651). Seeded from the stored value only — never from the signed-in
	/// account: prefill is a capture-time convenience, and re-applying it here would rewrite the
	/// credit on findings captured by, or already shared with, someone else.
	@State private var author = ""
	@State private var gps = ""
	@State private var saveFailed = false

	@State private var shareSubject: FindingShareSubject?

	/// Inspect-only view state for the stored snapshot — never persisted (the
	/// stored image/box are fixed; the save sheet owns crop editing).
	@State private var highlightOpacity: Double = 1
	@State private var snapshotZoom: CGFloat = 1

	var body: some View {
		List {
			snapshotSection
			titleSection
			labelSection
			noteSection
			authorSection
			gpsSection
			detectionSection
			pageSection
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
			} else {
				Image(systemName: "photo")
					.font(.largeTitle)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity)
					.padding(.vertical, 32)
			}
		}
	}

	private var titleSection: some View {
		Section(L10n.Finding.title) {
			TextField(L10n.Finding.titlePlaceholder, text: $title)
				.testability(Testability.TextField.findingDetailTitle)
		}
	}

	private var labelSection: some View {
		Section(L10n.Finding.label) {
			TextField(L10n.Finding.labelPlaceholder, text: $label)
				.testability(Testability.TextField.findingDetailLabel)
		}
	}

	private var noteSection: some View {
		Section(L10n.Finding.note) {
			TextField(L10n.Finding.notePlaceholder, text: $note, axis: .vertical)
				.lineLimit(3...6)
				.testability(Testability.TextField.findingDetailNote)
		}
	}

	private var authorSection: some View {
		Section(L10n.Finding.author) {
			TextField(L10n.Finding.authorPlaceholder, text: $author)
				.testability(Testability.TextField.findingDetailAuthor)
		}
	}

	private var gpsSection: some View {
		Section(L10n.Finding.gps) {
			TextField(L10n.Finding.gpsPlaceholder, text: $gps)
				.keyboardType(.numbersAndPunctuation)
				.testability(Testability.TextField.findingDetailGps)
		}
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
		if let page = finding.page {
			Section(L10n.Finding.page) {
				Text(page.absoluteString)
					.font(.caption)
					.foregroundStyle(.secondary)
					.contextMenu {
						Button {
							UIPasteboard.general.string = page.absoluteString
						} label: {
							Label(L10n.Common.copy, systemImage: "doc.on.doc")
						}
					}
				Button {
					onOpenPage(page)
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
			Button(action: saveEdits) {
				Text(L10n.Finding.Save.action)
					.bold()
			}
			.disabled(hasChanges.not || trimmedTitle.isEmpty)
			.tint(.green)
			.testability(Testability.Button.findingDetailSave)
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
	}

	private func saveEdits() {
		finding.title = trimmedTitle
		finding.label_ = normalized(label)
		finding.note_ = normalized(note)
		finding.author = normalized(author)
		finding.gps_ = normalized(gps)
		do {
			try Finding.save(in: moc)
		} catch {
			LoggingPolicy.error("Failed to save finding edits", error: error, logger: .storage)
			// Reload from the store so the fields reflect the persisted state
			// instead of silently diverging from it (ConfigurationRow precedent).
			moc.refresh(finding, mergeChanges: false)
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
private struct InspectableHighlightedSnapshot: View {
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

// MARK: - Mac-only context menu

private extension View {
	/// Attaches a context menu only when running on a Mac (right-click is the Mac
	/// idiom). On touch the menu is suppressed — the leading swipe shares instead.
	@ViewBuilder
	func macContextMenu<MenuItems: View>(@ViewBuilder _ menuItems: () -> MenuItems) -> some View {
		if ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp {
			contextMenu(menuItems: menuItems)
		} else {
			self
		}
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

// MARK: - Crop helpers

extension Finding {
	/// The user-facing name. `title` is required for new findings; the fallback
	/// only covers any legacy/empty (or whitespace-only) row so the list never
	/// shows a blank line.
	var displayTitle: String {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? (label_ ?? detectionClass ?? L10n.Finding.detection) : trimmed
	}

	/// The stored bounding box as a Vision-normalized full-image rect.
	var normalizedBox: CGRect {
		CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
	}

	/// Cropped detection thumbnail from the stored snapshot. The pixel rect is
	/// computed against the cgImage's own dimensions — multiplying a pixel-based
	/// rect by `UIImage.scale` would double-scale it.
	func cropThumbnail() -> UIImage? {
		guard
			let image = FindingScreenshotStore.load(filename: screenshotFilename),
			let cgImage = image.cgImage
		else { return nil }
		let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
		// `.integral` can round an edge-touching rect past the image bounds;
		// intersect so the crop request is always fully inside (croppedCapture
		// in SaveFindingSheet does the same).
		let pixelRect = normalizedBox.visionRect(in: bounds.size).integral.intersection(bounds)
		guard pixelRect.width > 0, pixelRect.height > 0, let crop = cgImage.cropping(to: pixelRect) else { return nil }
		return UIImage(cgImage: crop)
	}
}
