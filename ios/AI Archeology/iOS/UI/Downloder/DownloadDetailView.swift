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
	@State private var isFormValid: Bool = false // TODO: use PreferenceKey to validate the components
	@State private var progress: Double = 0.0
	@State private var totalBytesWritten: Int = 0
	@State private var totalBytesExpected: Int = 0

	var body: some View {
        Group {
            VStack {
                ProgressView(value: [.complete, .imported].contains(item.state) ? 1.0 : progress)
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
                            TextField("https://.../mymodel.mlmodel", // TODO: alignment of the hint on the trailing side
                                      text: $urlText, axis: .vertical)
                            .disabled([Downloader.State.downloading, Downloader.State.paused].contains(item.state))
                            .lineLimit(5)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: urlText) { value in
                                item.url = URL(string: urlText)
                                item.transition(to: .draft)
                                item.persist(in: moc)

                                validateUrl(value) // But do not enable the download button, if the URL is not valid.
                            }
                            .onAppear {
                                validateUrl(urlText)
                            }
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Button("Clear") {
                                        urlText = ""
                                    }
                                    .foregroundColor(.blue)
                                    Spacer()
                                    Button("Done") {
                                        Self.removeFocus()
                                    }
                                }
                            }
                        }
                    } footer: {
                        Text("Provide a valid address pointing to a Create ML detection model (.mlmodel)")
                            .font(.subheadline)
                            .foregroundColor(.gray)
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
                    Section {
                        HStack {
                            Spacer()
                            Button(action: {
                                self.showAlert = true
                            }) {
                                Image(systemName: "questionmark.circle") // Using a system image for the question mark
                                    .foregroundColor(.blue)
                                    .font(Font.title3) // Adjust size as needed
                            }
                        }
                        .padding(.trailing, -17)
                    }
                    .listRowBackground(Color.clear)
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
                .padding(20)
            }
        }
        .navigationBarTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear {
            #if false && DEBUG //debugging data
               // item.url = URL(string: "http://172.20.10.13:2343/HroudaDetector.mlmodel")
            item.url = URL(string: "http://192.168.178.49:2344/HroudaDetector.mlmodel")
            isFormValid = true
            #endif

            urlText = item.url?.absoluteString ?? ""
        }
        .alert(isPresented: $showAlert) {
            Alert(
                title: Text("Import"),
                message: Text(
                    """
                    In order to import a model succesfully, the  download has to be complete, and no deep configuration (side menu in the app) should use this model already - the model should not be already imported.
                    To reimport the model, first delete the deep configuration from the app's side menu with swipe gesture, and then you will be able to import the file from this form again.
                    """
                ),
                dismissButton: .default(Text("Got it!"))
            )
        }
	}
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if sizeClass == .compact {
            ToolbarItem(placement: .topBarTrailing) { importButton }
        } else {
            ToolbarItem(placement: .topBarLeading)  { importButton }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Dismiss") { dismiss() }
                    .bold()
                    .foregroundColor(.blue)
            }
        }
    }
        
    private var canImport: Bool {
        let entityId = item.entityId
        guard
            [.complete, .imported].contains(item.state),
            let url = item.url, !url.absoluteString.isEmpty,
            item.doesModelFileExist(),
            deep.selectConfiguration(entityId).isNil
        else { return false }
        return true
    }
    
    private var importButton: some View {
        Button("Import") {
            let entityId = item.entityId
            guard let file = item.file else { return }
            onImport.call(file, entityId, downloader)
        }
        .bold()
        .foregroundColor(canImport ? .green : .gray)
        .disabled(!canImport)
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
