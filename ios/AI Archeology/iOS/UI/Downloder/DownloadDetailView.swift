//
//  DownloadDetailView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.12.23.
//

import SwiftUI

struct DownloadDetailView: View {
	@Environment(\.managedObjectContext) var moc
	@EnvironmentObject var downloader: Downloader
	@EnvironmentObject var deep: DeepState

	@ObservedObject var item: DownloadItem
	@State private var urlText: String = ""
	@State private var isFormValid: Bool = false // TODO: use PreferenceKey to validate the components
	@State private var progress: Double = 0.0
	@State private var totalBytesWritten: Int = 0
	@State private var totalBytesExpected: Int = 0

	var body: some View {
		if item.entityId.isNotNil {
			Group {
				VStack {
					ProgressView(value: [.completed, .imported].contains(item.state) ? 1.0 : progress)
						.progressViewStyle(LinearProgressViewStyle(tint: .green))
						.frame(height: 5)
						.onReceive(downloader.progressPublisher(for: item.entityId)) { newProgress in // Core data properties are optional
							progress = newProgress
						}
					Form {
						Section {
							HStack {
								Text("URL")
								Spacer()
								TextField("example: https://.../mymodel.mlmodel", // TODO: alignment of the hint on the trailing side
										  text: $urlText, axis: .vertical)
								.disabled([Downloader.State.downloading, Downloader.State.paused].contains(item.state))
								.lineLimit(3)
								.autocapitalization(.none)
								.disableAutocorrection(true)
								.multilineTextAlignment(.trailing)
								.onChange(of: urlText) { value in
									item.url = URL(string: urlText)
										// Keep the record even if the URL is not valid. But do not enable the download button.
									item.readyToValidate = true
									DownloadItem.save(in: moc)

									validateUrl(value)
								}
								.onAppear {
									validateUrl(urlText)
								}
							}
						}

						Section {
							HStack {
								Text("Status")
								Spacer()
								Text(item.state.id)
									.foregroundColor(.gray)
							}
							HStack {
								Text("Downloaded")
								Spacer()
								if item.state == .downloading {
									ProgressDetailTextView(totalBytesWritten.formatBytesAsHumanReadable(),
														   totalBytesExpected.formatBytesAsHumanReadable())
										.onReceive(downloader.totalBytesWrittenPublisher(for: item.entityId)) { newValue in
											totalBytesWritten = newValue
										}
										.onReceive(downloader.totalBytesExpectedPublisher(for: item.entityId)) { newValue in
											totalBytesExpected = newValue
										}
										.foregroundColor(.gray)
								} else {
									ProgressDetailTextView(Int($item.totalBytesWritten.wrappedValue).formatBytesAsHumanReadable(),
														   Int($item.totalBytesExpectedToWrite.wrappedValue).formatBytesAsHumanReadable())
										.foregroundColor(.gray)
								}
							}
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
					HStack {
						Spacer()
						Button(Self.downloadButtonAttributes(item.state).label, action: {
							Task {
								item.error = nil
								downloader.downloadTapped(item)
							}
						})
						.buttonStyle(PressableButtonStyle(color: isFormValid ? Self.downloadButtonAttributes(item.state).color : .gray))
						.disabled(Self.downloadButtonAttributes(item.state).enabled.not || isFormValid.not)
						Spacer()
						Button(Self.cancelButtonAttributes(item.state).label, action: {
							Task {
								downloader.cancelTapped(item)
							}
						})
						.buttonStyle(PressableButtonStyle(color: Self.cancelButtonAttributes(item.state).color))
						.disabled(Self.cancelButtonAttributes(item.state).enabled.not)
						Spacer()
					}
					.centerInParentView()
				}
			}
			.onAppear {
				#if false && DEBUG //debugging data
				   // item.url = URL(string: "http://172.20.10.13:2343/HroudaDetector.mlmodel")
				item.url = URL(string: "http://192.168.178.49:2344/HroudaDetector.mlmodel")
				isFormValid = true
				#endif

				urlText = item.url?.absoluteString ?? ""
			}
		}
	}

	private func validateUrl(_ value: String) {
		let invalidURLs = ["https:", "http:", "https://", "http://", "https:/", "http:/"]
		if invalidURLs.contains(value) {
			isFormValid = false
			return
		}
		guard let url = URL(string: value) else {
			isFormValid = false
			return
		}
		if UIApplication.shared.canOpenURL(url) {
			isFormValid = true
		}
	}

	static func downloadButtonAttributes(_ state: Downloader.State) -> (enabled: Bool, color: Color, label: String) {
		switch state {
		case .notStarted, .imported: return (enabled: true, color: .blue, label: "Download")
		case .cancelled, .failed, .completed: return (enabled: true, color: .blue, label: "Restart")
		case .paused: return (enabled: true, color: .green, label: "Continue")
		case .downloading: return (enabled: true, color: .orange, label: "Pause")
		}
	}

	static func cancelButtonAttributes(_ state: Downloader.State) -> (enabled: Bool, color: Color, label: String) {
		switch state {
		case .notStarted, .cancelled, .failed, .completed, .imported: return (enabled: false, color: .gray, label: "Cancel")
		case .paused, .downloading: return (enabled: true, color: .red, label: "Cancel")
		}
	}

}

fileprivate struct ProgressDetailTextView: View {
	var totalBytesWritten: String
	var totalBytesExpected: String

	init(_ totalBytesWritten: String, _ totalBytesExpected: String) {
		self.totalBytesWritten = totalBytesWritten
		self.totalBytesExpected = totalBytesExpected
	}
	var body: some View {
		HStack {
			Text(totalBytesWritten)
				.multilineTextAlignment(.trailing)
			Text("/ \(totalBytesExpected)")
		}
	}
}
