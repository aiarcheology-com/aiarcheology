//
//  DownloadDetailView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.12.23.
//

import SwiftUI
import OSLog

struct DownloadDetailView: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.horizontalSizeClass) private var sizeClass
	@Environment(\.managedObjectContext) private var moc
	@EnvironmentObject var downloader: Downloader
	@EnvironmentObject var deep: DeepState
	
	@ObservedObject var item: DownloadItem
	let onImport: ImportHandler

	/// Configurations matching this download, fetched live. `deep.selectConfiguration` is a plain
	/// Core Data fetch and `DeepState` publishes no configuration-list change, so a configuration
	/// created or deleted while this screen is open would leave the import button stale (AIA-0459,
	/// codex review). A `@FetchRequest` re-renders on the context's changes.
	@FetchRequest private var matchingConfigurations: FetchedResults<DeepConfiguration>

	init(item: DownloadItem, onImport: ImportHandler) {
		self.item = item
		self.onImport = onImport
		_matchingConfigurations = FetchRequest(
			sortDescriptors: [],
			predicate: NSPredicate(format: "entityId == %@", item.entityId as CVarArg)
		)
	}

	@FocusState private var isUrlFieldFocused: Bool
	@State private var showAlert = false
	@State private var urlText: String = ""
	@State private var isFormValid: Bool = false
	@State private var progress: Double = 0.0
	@State private var totalBytesWritten: Int = 0
	@State private var totalBytesExpected: Int = 0
	@State private var packageFileProgress = PackageFileProgress(completedFileCount: 0, totalFileCount: 0)
	
	// MARK: - Body
	
	var body: some View {
		VStack(spacing: 0) {
			progressHeader
			Form {
				urlInputSection
				statusSection
				importSection
				helpSection
			}
		}
		.safeAreaInset(edge: .bottom, spacing: 0) {
			actionButtons
				.background(.bar)
		}
		.navigationBarTitle(isCatalogDownload ? L10n.Catalog.Download.title : L10n.Download.title)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar { toolbarContent }
		.onAppear {
			let value = item.url?.absoluteString ?? ""
			urlText = value
			validateUrl(value)
		}
		.alert(L10n.Download.Help.title, isPresented: $showAlert) {
			Button(L10n.Common.ok, role: .cancel) { }
		} message: {
			Text(Self.helpMessage)
		}
	}
}

// MARK: - Header & Progress

private extension DownloadDetailView {
	var progressHeader: some View {
		ProgressView(value: progressValue)
			.testability(Testability.ProgressView.downloadDetailProgress)
			.progressViewStyle(LinearProgressViewStyle(tint: .green))
			.frame(height: 5)
			.onReceive(downloader.progressPublisher(for: item.entityId)) { newProgress in
				progress = newProgress
			}
	}
	
	/// Returns the appropriate progress value based on download state:
	/// - Complete/Imported: 1.0
	/// - Downloading: live progress from publisher
	/// - Paused/Other: persisted progress from CoreData
	///
	/// This prevents the progress bar from resetting to 0.0 when pausing.
	var progressValue: Double {
		switch item.state {
		case .complete, .imported:
			return 1.0
		case .downloading:
			return progress
		default:
			// When paused or in other states, use the persisted progress
			return item.progress
		}
	}
}

// MARK: - URL Input Section

private extension DownloadDetailView {
	var urlInputSection: some View {
		Section {
			if isCatalogDownload {
				catalogArtifactInput
			} else {
				HStack(alignment: .top, spacing: 8) {
					urlLabel
					Spacer(minLength: 8)
					urlInput
				}
			}
		} footer: {
			if let packageProgressDescription {
				if packageFileCount != nil {
					Text(packageProgressDescription)
						.font(.subheadline)
						.foregroundColor(.gray)
						.onReceive(downloader.packageFileProgressPublisher(for: item.entityId)) { progress in
							packageFileProgress = progress
						}
				} else {
					Text(packageProgressDescription)
						.font(.subheadline)
						.foregroundColor(.gray)
				}
			}
		}
	}
	
	var catalogArtifactInput: some View {
		HStack(alignment: .top, spacing: 8) {
			HStack(spacing: 6) {
				Text(downloader.isPackageDownload(item) ? L10n.Catalog.Download.package : L10n.Configuration.Section.model)
				copyUrlButton
			}
			Spacer(minLength: 8)
			Text(downloader.catalogArtifactName(for: item) ?? urlText)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.trailing)
		}
	}

	var urlLabel: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(L10n.Download.url)
			copyUrlButton
		}
	}

	var copyUrlButton: some View {
		Button {
			UIPasteboard.general.string = urlText
		} label: {
			Image(systemName: "doc.on.doc")
		}
		.accessibilityLabel(L10n.Common.copy)
		.buttonStyle(.borderless)
		.testability(Testability.Button.downloadDetailCopyUrl)
	}

	@ViewBuilder
	var urlInput: some View {
		if isURLReadOnly {
			Text(urlText)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.trailing)
				.textSelection(.enabled)
		} else {
			urlTextField
		}
	}

	var isURLReadOnly: Bool {
		isCatalogDownload || [.downloading, .paused].contains(item.state)
	}

	var urlTextField: some View {
		TextField(L10n.Download.urlPlaceholder, text: $urlText, axis: .vertical)
			.testability(Testability.TextField.downloadDetailUrl)
			.lineLimit(5)
			.autocapitalization(.none)
			.disableAutocorrection(true)
			.multilineTextAlignment(.trailing)
			.onChange(of: urlText) { _, newValue in
				// In-memory updates + cheap validation only; persisting on every
				// keystroke writes to disk per typed character.
				item.url = URL(string: newValue)
				item.transition(to: .draft)
				validateUrl(newValue)
			}
			.onChange(of: isUrlFieldFocused) { _, focused in
				if !focused {
					persistUrl()
				}
			}
			.onSubmit { persistUrl() }
			.onAppear { validateUrl(urlText) }
			.focused($isUrlFieldFocused)
	}
}

// MARK: - Status Section

private extension DownloadDetailView {
	var statusSection: some View {
		Section {
			statusRow
			downloadedRow
			errorRow
		}
	}
	
	var statusRow: some View {
		HStack {
			Text(L10n.Download.status)
			Spacer()
			Text(item.state.localizedName)
				.foregroundColor(.gray)
		}
	}

	var downloadedRow: some View {
		HStack {
			Text(L10n.Download.downloaded)
			Spacer()
			downloadProgressText
				.foregroundColor(.gray)
		}
	}
	
	@ViewBuilder
	var downloadProgressText: some View {
		if item.state == .downloading {
			ProgressDetailTextView(
				totalBytesWritten.formatBytesAsHumanReadable(),
				totalBytesExpected.formatBytesAsHumanReadable()
			)
			.onReceive(downloader.totalBytesWrittenPublisher(for: item.entityId)) { newValue in
				totalBytesWritten = newValue
			}
			.onReceive(downloader.totalBytesExpectedPublisher(for: item.entityId)) { newValue in
				totalBytesExpected = newValue
			}
		} else {
			let written = Int($item.totalBytesWritten.wrappedValue)
			let expected = Int($item.totalBytesExpectedToWrite.wrappedValue)
			ProgressDetailTextView(
				written.formatBytesAsHumanReadable(),
				completedExpectedBytes(written: written, expected: expected).formatBytesAsHumanReadable()
			)
		}
	}

	private func completedExpectedBytes(written: Int, expected: Int) -> Int {
		guard item.state == .complete || item.state == .imported else { return expected }
		return Downloader.completedExpectedBytes(written: written, expected: expected)
	}
	
	@ViewBuilder
	var errorRow: some View {
		if let error = item.error {
			HStack {
				Text(L10n.Download.error)
					.foregroundColor(.red)
				Spacer()
				Text(error)
					.multilineTextAlignment(.trailing)
					.lineLimit(5)
					.foregroundColor(.gray)
			}
		}
	}
}

// MARK: - Help Section

private extension DownloadDetailView {
	var helpSection: some View {
		Section {
			HStack {
				Spacer()
				Button(action: { showAlert = true }) {
					Image(systemName: "questionmark.circle")
						.foregroundColor(.blue)
						.font(.title3)
				}
				.testability(Testability.Button.downloadDetailHelp)
			}
			.padding(.trailing, -17)
		}
		.listRowBackground(Color.clear)
	}
	
	static var helpMessage: String {
		"""
		In order to import a model succesfully, the download has to be complete, and no deep configuration (side menu in the app) should use this model already - the model should not be already imported.
		To reimport the model, first delete the deep configuration from the app's side menu with swipe gesture, and then you will be able to import the file from this form again.
		"""
	}
}

// MARK: - Action Buttons

private extension DownloadDetailView {
	var actionButtons: some View {
		HStack {
			Spacer()
			downloadButton
			Spacer()
			cancelButton
			Spacer()
		}
		.padding(20)
	}
	
	var downloadButton: some View {
		let attributes = downloadAttributes
		return Button(attributes.label) {
			Task {
				item.error = nil
				persistUrl()
				downloader.downloadTapped(item)
			}
		}
		.buttonStyle(PressableButtonStyle(color: isFormValid ? attributes.color : .gray))
		.disabled(!attributes.enabled || !isFormValid)
		.testability(Testability.Button.downloadDetailState)
	}
	
	var cancelButton: some View {
		let attributes = Self.cancelButtonAttributes(item.state)
		return Button(attributes.label) {
			Task { downloader.cancelTapped(item) }
		}
		.buttonStyle(PressableButtonStyle(color: attributes.color))
		.disabled(!attributes.enabled)
		.testability(Testability.Button.downloadDetailCancel)
	}
}

private extension DownloadDetailView {
	var isPackageDownload: Bool {
		downloader.isPackageDownload(item)
	}

	var isCatalogDownload: Bool {
		downloader.isCatalogDownload(item)
	}

	var packageFileCount: Int? {
		downloader.packageFileCount(for: item)
	}

	var packageProgressDescription: String? {
		guard let packageFileCount else { return L10n.Download.urlHintFormats }
		switch item.state {
		case .complete, .imported:
			return L10n.Catalog.Download.progress(packageFileCount, packageFileCount)
		case .downloading:
			return L10n.Catalog.Download.progress(
				min(packageFileProgress.completedFileCount, packageFileCount),
				packageFileCount
			)
		default:
			return nil
		}
	}

	var downloadAttributes: (enabled: Bool, color: Color, label: String) {
		if isCatalogDownload, item.state == .downloading {
			return (enabled: false, color: .gray, label: L10n.DownloadState.downloading)
		}
		return Self.downloadButtonAttributes(item.state)
	}
}

// MARK: - Toolbar

private extension DownloadDetailView {
	@ToolbarContentBuilder
	var toolbarContent: some ToolbarContent {
		// Import is NOT here any more (AIA-0757). It sat in the navigation bar while the large
		// in-body Download/Restart button did not, so once a download finished the prominent control
		// was the wrong one — testers pressed Restart. It now lives in the form, between the progress
		// rows and the action bar.
		if sizeClass != .compact {
			ToolbarItem(placement: .topBarTrailing) {
				Button(L10n.Common.dismiss) { dismiss() }
					.bold()
					.foregroundColor(.blue)
					.testability(Testability.Button.downloadDetailDismiss)
			}
		}
		
		ToolbarItemGroup(placement: .keyboard) {
			if isUrlFieldFocused {
				Button(L10n.Common.clear) {
					urlText = ""
				}
				.foregroundColor(.blue)
				.testability(Testability.Button.downloadDetailClear)
				Spacer()
				Button(L10n.Common.done) {
					isUrlFieldFocused = false
				}
				.testability(Testability.Button.downloadDetailDone)
			}
		}
	}
	
	/// Import's own row in the form, directly under the progress and byte counts and directly above
	/// the Download/Cancel bar — the place the eye lands once a download completes (AIA-0757).
	///
	/// Deliberately in the `Form` rather than in the pinned `safeAreaInset` alongside Download and
	/// Cancel: that inset is chrome and stays put, so Import would hover there while the very rows
	/// that say the download is finished scrolled away behind it.
	var importSection: some View {
		Section {
			HStack {
				Spacer()
				importButton
				Spacer()
			}
		}
		.listRowBackground(Color.clear)
	}

	var importButton: some View {
		// "Imported" means a deep configuration exists for this item — the same condition that
		// disables the button below. The download state alone is not enough: import paths that
		// bypass the downloader's state machine leave it at .complete, and conversely a deleted
		// configuration re-enables import while the state stays .imported (AIA-0459).
		return Button(isImported ? L10n.Common.imported : L10n.Common.import) {
			let entityId = item.entityId
			guard let file = item.file,
				  let url = item.url
			else { return }
			
			onImport.call(file, entityId, url, downloader)
		}
		// Matches Download and Cancel so the three read as peers. The colour is passed in rather
		// than left to the disabled state: `PressableButtonStyle` paints white on whatever colour it
		// is given and never inspects `isEnabled`, so without this an inactive Import would still
		// look like the thing to press.
		.buttonStyle(PressableButtonStyle(color: canImport ? .green : .gray))
		.disabled(!canImport)
		.testability(Testability.Button.downloadDetailImport)
	}
	
	/// True once this download has a deep configuration — i.e. the model was imported. Read from the
	/// live fetch so both the label and `canImport` react to a configuration appearing or being
	/// deleted while this screen is open.
	var isImported: Bool {
		matchingConfigurations.isEmpty.not
	}

	var canImport: Bool {
		guard
			[.complete, .imported, .importFailed].contains(item.state),
			let url = item.url, !url.absoluteString.isEmpty,
			item.doesModelFileExist(),
			isImported.not
		else { return false }
		return true
	}
}

// MARK: - Validation & Button Attributes

private extension DownloadDetailView {
	func persistUrl() {
		do {
			try item.persist(in: moc)
		} catch {
			// Log the technical error; show the user a friendly, localized message.
			LoggingPolicy.error("Failed to persist download item URL", error: error, logger: .networking)
			item.error = L10n.Download.Error.persistFailed
		}
	}

	func validateUrl(_ value: String) {
		// URLComponents parsing replaces the canOpenURL sync IPC per keystroke and
		// enforces an http(s) scheme allow-list for the download sink.
		guard let components = URLComponents(string: value),
			  let scheme = components.scheme?.lowercased(),
			  ["http", "https"].contains(scheme),
			  let host = components.host, !host.isEmpty
		else {
			isFormValid = false
			return
		}
		isFormValid = true
	}
	
	static func downloadButtonAttributes(_ state: Downloader.State) -> (enabled: Bool, color: Color, label: String) {
		switch state {
		case .notStarted, .imported: return (enabled: true, color: .blue, label: L10n.Download.Button.download)
		case .cancelled, .failed, .complete, .importFailed: return (enabled: true, color: .blue, label: L10n.Download.Button.restart)
		case .paused: return (enabled: true, color: .green, label: L10n.Download.Button.continue)
		case .downloading: return (enabled: true, color: .orange, label: L10n.Download.Button.pause)
		}
	}

	static func cancelButtonAttributes(_ state: Downloader.State) -> (enabled: Bool, color: Color, label: String) {
		switch state {
		case .notStarted, .cancelled, .failed, .complete, .imported, .importFailed: return (enabled: false, color: .gray, label: L10n.Download.Button.cancel)
		case .paused, .downloading: return (enabled: true, color: .red, label: L10n.Download.Button.cancel)
		}
	}
}

// MARK: - Supporting Views

private struct ProgressDetailTextView: View {
	let totalBytesWritten: String
	let totalBytesExpected: String
	
	init(_ totalBytesWritten: String, _ totalBytesExpected: String) {
		self.totalBytesWritten = totalBytesWritten
		self.totalBytesExpected = totalBytesExpected
	}
	
	var body: some View {
		HStack {
			Text(totalBytesWritten)
				.multilineTextAlignment(.trailing)
				.testability(Testability.Label.downloadDetailProgressWritten)
			Text("/ \(totalBytesExpected)")
				.testability(Testability.Label.downloadDetailProgressExpected)
		}
	}
}
