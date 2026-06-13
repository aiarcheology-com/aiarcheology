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

	@Environment(\.displayScale) private var displayScale
	@Environment(\.colorScheme) private var colorScheme

	/// Drives the system share sheet for both the ZIP export and per-row sharing.
	/// The modal presentation is what serializes them — only one can be up at a time.
	@State private var sharePayload: FindingSharePayload?
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
							.bold()
					}
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
		.sheet(item: $sharePayload) { payload in
			ActivityShareSheet(items: payload.items)
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
				Label(L10n.Findings.export, systemImage: "square.and.arrow.up")
			}
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
				sharePayload = FindingSharePayload(items: [url])
			} catch {
				LoggingPolicy.error("Failed to export findings", error: error, logger: .storage)
				exportFailed = true
			}
			isExporting = false
		}
	}

	private func share(_ finding: Finding) {
		FindingShareCard.shareItems(for: finding, scale: displayScale, colorScheme: colorScheme) { items in
			sharePayload = FindingSharePayload(items: items)
		}
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
					Text(finding.label_ ?? finding.detectionClass ?? L10n.Finding.detection)
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
		.contextMenu {
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
	@ObservedObject var finding: Finding
	let onOpenPage: (URL) -> Void

	@State private var label = ""
	@State private var note = ""
	@State private var gps = ""
	@State private var saveFailed = false

	@Environment(\.displayScale) private var displayScale
	@Environment(\.colorScheme) private var colorScheme
	@State private var sharePayload: FindingSharePayload?

	var body: some View {
		List {
			Section {
				if let image = FindingScreenshotStore.load(filename: finding.screenshotFilename) {
					HighlightedSnapshotView(image: image, normalizedBox: finding.normalizedBox, color: .red)
				} else {
					Image(systemName: "photo")
						.font(.largeTitle)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 32)
				}
			}
			Section(L10n.Finding.label) {
				TextField(L10n.Finding.labelPlaceholder, text: $label)
					.testability(Testability.TextField.findingDetailLabel)
			}
			Section(L10n.Finding.note) {
				TextField(L10n.Finding.notePlaceholder, text: $note, axis: .vertical)
					.lineLimit(3...6)
					.testability(Testability.TextField.findingDetailNote)
			}
			Section(L10n.Finding.gps) {
				TextField(L10n.Finding.gpsPlaceholder, text: $gps)
					.keyboardType(.numbersAndPunctuation)
					.testability(Testability.TextField.findingDetailGps)
			}
			if let detectionClass = finding.detectionClass {
				Section(L10n.Finding.detection) {
					// verbatim: class names are model vocabulary, not localizable —
					// and plain interpolation gets auto-extracted into the catalog.
					Text(verbatim: "\(detectionClass) (\(Int(finding.detectionConfidence * 100))%)")
						.foregroundStyle(.secondary)
				}
			}
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
		.navigationTitle(finding.label_ ?? finding.detectionClass ?? L10n.Findings.title)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItemGroup(placement: .navigationBarTrailing) {
				Button(action: shareFinding) {
					Label(L10n.Common.share, systemImage: "square.and.arrow.up")
				}
				.testability(Testability.Button.findingDetailShare)
				Button(action: saveEdits) {
					Text(L10n.Finding.Save.action)
						.bold()
				}
				.disabled(hasChanges.not)
				.testability(Testability.Button.findingDetailSave)
			}
		}
		.alert(L10n.Finding.Save.error, isPresented: $saveFailed) {
			Button(L10n.Common.ok, role: .cancel) {}
		}
		.sheet(item: $sharePayload) { payload in
			ActivityShareSheet(items: payload.items)
		}
		.onAppear(perform: seedFields)
	}

	private func shareFinding() {
		FindingShareCard.shareItems(for: finding, scale: displayScale, colorScheme: colorScheme) { items in
			sharePayload = FindingSharePayload(items: items)
		}
	}

	// MARK: - Editing

	private var hasChanges: Bool {
		normalized(label) != finding.label_
			|| normalized(note) != finding.note_
			|| normalized(gps) != finding.gps_
	}

	private func seedFields() {
		label = finding.label_ ?? ""
		note = finding.note_ ?? ""
		gps = finding.gps_ ?? ""
	}

	private func saveEdits() {
		finding.label_ = normalized(label)
		finding.note_ = normalized(note)
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

// MARK: - Highlighted snapshot

/// Renders a snapshot with a Vision-normalized box highlighted at full opacity.
/// The overlay's geometry IS the fitted image rect (it sizes to the fitted Image),
/// so the shared bottom-left→top-left transform applies without letterbox math.
/// Used by the save sheet's preview and the finding detail.
struct HighlightedSnapshotView: View {
	let image: UIImage
	let normalizedBox: CGRect
	let color: Color

	var body: some View {
		Image(uiImage: image)
			.resizable()
			.scaledToFit()
			.overlay {
				GeometryReader { imageGeometry in
					let rect = normalizedBox.visionRect(in: imageGeometry.size)
					Rectangle()
						.stroke(color, lineWidth: 2)
						.frame(width: rect.width, height: rect.height)
						.position(x: rect.midX, y: rect.midY)
				}
			}
			.frame(maxWidth: .infinity)
	}
}

// MARK: - Crop helpers

extension Finding {
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
