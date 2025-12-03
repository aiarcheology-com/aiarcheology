//
//  DownloadDetailView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.12.23.
//

import SwiftUI

struct DownloadDetailView: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.horizontalSizeClass) private var sizeClass
	@Environment(\.managedObjectContext) private var moc
	@EnvironmentObject var downloader: Downloader
	@EnvironmentObject var deep: DeepState
	
	@ObservedObject var item: DownloadItem
	let onImport: ImportHandler
	
	@State private var showAlert = false
	@State private var urlText: String = ""
	@State private var isFormValid: Bool = false
	@State private var progress: Double = 0.0
	@State private var totalBytesWritten: Int = 0
	@State private var totalBytesExpected: Int = 0
	
	// MARK: - Body
	
	var body: some View {
		VStack {
			progressHeader
			Form {
				urlInputSection
				statusSection
				helpSection
			}
			actionButtons
		}
		.navigationBarTitle("Model")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar { toolbarContent }
		.onAppear { urlText = item.url?.absoluteString ?? "" }
		.alert("Help", isPresented: $showAlert) {
			Button("OK", role: .cancel) { }
		} message: {
			Text(Self.helpMessage)
		}
	}
}

// MARK: - Header & Progress

private extension DownloadDetailView {
	var progressHeader: some View {
		ProgressView(value: [.complete, .imported].contains(item.state) ? 1.0 : progress)
			.testability(Testability.ProgressView.downloadDetailProgress)
			.progressViewStyle(LinearProgressViewStyle(tint: .green))
			.frame(height: 5)
			.onReceive(downloader.progressPublisher(for: item.entityId)) { newProgress in
				progress = newProgress
			}
	}
}

// MARK: - URL Input Section

private extension DownloadDetailView {
	var urlInputSection: some View {
		Section {
			HStack {
				Text("URL")
				Spacer()
				urlTextField
			}
		} footer: {
			Text("Provide a valid address pointing to a Create ML detection model (.mlmodel)")
				.font(.subheadline)
				.foregroundColor(.gray)
		}
	}
	
	var urlTextField: some View {
		TextField("https://.../mymodel.mlmodel", text: $urlText, axis: .vertical)
			.testability(Testability.TextField.downloadDetailUrl)
			.disabled([.downloading, .paused].contains(item.state))
			.lineLimit(5)
			.autocapitalization(.none)
			.disableAutocorrection(true)
			.multilineTextAlignment(.trailing)
			.onChange(of: urlText) { value in
				item.url = URL(string: urlText)
				item.transition(to: .draft)
				item.persist(in: moc)
				validateUrl(value)
			}
			.onAppear { validateUrl(urlText) }
			.toolbar {
				ToolbarItemGroup(placement: .keyboard) {
					Button("Clear") { urlText = "" }
						.foregroundColor(.blue)
						.testability(Testability.Button.downloadDetailClear)
					Spacer()
					Button("Done") { Self.removeFocus() }
						.testability(Testability.Button.downloadDetailDone)
				}
			}
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
			Text("Status")
			Spacer()
			Text(item.state.id)
				.foregroundColor(.gray)
		}
	}
	
	var downloadedRow: some View {
		HStack {
			Text("Downloaded")
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
			ProgressDetailTextView(
				Int($item.totalBytesWritten.wrappedValue).formatBytesAsHumanReadable(),
				Int($item.totalBytesExpectedToWrite.wrappedValue).formatBytesAsHumanReadable()
			)
		}
	}
	
	@ViewBuilder
	var errorRow: some View {
		if let error = item.error {
			HStack {
				Text("Error")
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
		let attributes = Self.downloadButtonAttributes(item.state)
		return Button(attributes.label) {
			Task {
				item.error = nil
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

// MARK: - Toolbar

private extension DownloadDetailView {
	@ToolbarContentBuilder
	var toolbarContent: some ToolbarContent {
		if sizeClass == .compact {
			ToolbarItem(placement: .topBarTrailing) { importButton }
		} else {
			ToolbarItem(placement: .topBarLeading) { importButton }
			ToolbarItem(placement: .topBarTrailing) {
				Button("Dismiss") { dismiss() }
					.bold()
					.foregroundColor(.blue)
					.testability(Testability.Button.downloadDetailDismiss)
			}
		}
	}
	
	var importButton: some View {
		Button("Import") {
			let entityId = item.entityId
			guard let file = item.file else { return }
			onImport.call(file, entityId, downloader)
		}
		.bold()
		.foregroundColor(canImport ? .green : .gray)
		.disabled(!canImport)
		.testability(Testability.Button.downloadDetailImport)
	}
	
	var canImport: Bool {
		let entityId = item.entityId
		guard
			[.complete, .imported].contains(item.state),
			let url = item.url, !url.absoluteString.isEmpty,
			item.doesModelFileExist(),
			deep.selectConfiguration(entityId).isNil
		else { return false }
		return true
	}
}

// MARK: - Validation & Button Attributes

private extension DownloadDetailView {
	func validateUrl(_ value: String) {
		let invalidURLs = ["https:", "http:", "https://", "http://", "https:/", "http:/"]
		if invalidURLs.contains(value) {
			isFormValid = false
			return
		}
		guard let url = URL(string: value) else {
			isFormValid = false
			return
		}
		isFormValid = UIApplication.shared.canOpenURL(url)
	}
	
	static func downloadButtonAttributes(_ state: Downloader.State) -> (enabled: Bool, color: Color, label: String) {
		switch state {
		case .notStarted, .imported: return (enabled: true, color: .blue, label: "Download")
		case .cancelled, .failed, .complete: return (enabled: true, color: .blue, label: "Restart")
		case .paused: return (enabled: true, color: .green, label: "Continue")
		case .downloading: return (enabled: true, color: .orange, label: "Pause")
		}
	}
	
	static func cancelButtonAttributes(_ state: Downloader.State) -> (enabled: Bool, color: Color, label: String) {
		switch state {
		case .notStarted, .cancelled, .failed, .complete, .imported: return (enabled: false, color: .gray, label: "Cancel")
		case .paused, .downloading: return (enabled: true, color: .red, label: "Cancel")
		}
	}
}

// MARK: - Supporting Views

fileprivate struct ProgressDetailTextView: View {
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
