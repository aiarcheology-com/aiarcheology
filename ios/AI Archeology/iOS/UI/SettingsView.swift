//
//  SettingsView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 28.11.23.
//

	import SwiftUI

	struct SettingsForm: View {
		@Environment(\.dismiss) private var dismiss
		@EnvironmentObject var settings: Settings
		@EnvironmentObject var guide: Guide
		@State private var defaultWebPlaceholder: String = "www.google.com"
		@State private var validationErrorMessage: String?
		@State private var resetButtonColor: Color = .red
		@State private var showResetWarning = false

		var mergedObservable: [String] {[
			// Updated from the user's input:
			settings.snapFrequency.description,
			settings.snapAfterAppStart.description,
			settings.defaultPage?.description ?? "",
			settings.resetHistory.description,
		]}

		var body: some View {
			NavigationView {
				Form {
						// Detection Section
					Section(header: Text("Annotation")) {
						Picker("Frequency", selection: $settings.snapFrequency) {
							ForEach(1...10, id: \.self) { second in
								Text("\(second) second\(second > 1 ? "s" : "")").tag(Double(second))
							}
						}
						.onChange(of: settings.snapFrequency) { _ in
							guide.ontheflyDetectionResetTapped()
						}

						Toggle("Run At Launch", isOn: $settings.snapAfterAppStart)
						Toggle("Show labels", isOn: $settings.showIdentifiers)
					}

						// Web Content Section
					Section(header: Text("Web Content")) {
						HStack {
							Text("Default Page") // Label on the left
							Spacer()
							TextField(defaultWebPlaceholder, text: Binding(
								get: { settings.defaultPage?.absoluteString ?? "" },
								set: { newValue in
									settings.defaultPage = newValue.isEmpty ? nil : URL(string: newValue)
								}
							)) { changed in
								if changed {
									defaultWebPlaceholder = ""
								}
							}
							.multilineTextAlignment(.trailing)
							.foregroundColor(.gray)
						}
						Toggle("Reset History", isOn: $settings.resetHistory)
					}
					Section(header: Text("ML Browser")) {
						HStack {
							Text("Restore Defaults")
							Spacer()
							Button(action: {
								showResetWarning = true
							}) {
								Text("Restore")
							}
							.buttonStyle(PressableButtonStyle(color: resetButtonColor))
						}
						.onChange(of: settings.applicationResetButtonToggle) { reseted in
							resetButtonColor = .blue
						}
						NavigationLink(destination: AppDescriptionView()) {
							HStack {
								Text("About")
							}
						}
					}
				}
				.navigationBarTitle("Settings", displayMode: .inline)
				.navigationBarItems(trailing: Button(action: {
					do {
						try settings.validate()
						dismiss()
					} catch ValidationError.invalidData(let message) {
						validationErrorMessage = message
					} catch {
						validationErrorMessage = "An unexpected error occurred."
					}
				}) {

					Text("Dismiss").bold()
				})
				.alert(isPresented: .constant(validationErrorMessage != nil), content: {
					Alert(
						title: Text("Validation Error"),
						message: Text(validationErrorMessage ?? "An error occurred during validation."),
						dismissButton: .default(Text("OK"), action: {
							validationErrorMessage = nil // Reset the error message
						})
					)
				})
				.alert(isPresented: $showResetWarning) {
					Alert(
						title: Text("Warning"),
						message: Text("Resetting the application will erase all data models from the ML Browser. Are you sure you want to proceed?"),
						primaryButton: .destructive(Text("Reset"), action: guide.resetApplication),
						secondaryButton: .cancel()
					)
				}
				.onChange(of: mergedObservable) { _ in
					resetButtonColor = .red
				}
			}
		}
	}

struct AppDescriptionView: View {
	let versionString: String = appVersion()
	let appIcon: String = Bundle.main.iconFileName ?? "AppIcon"
	let emailAddress: String = "info@aiarcheology.com"
	private static let websiteURL = URL(string: "https://www.aiarcheology.com")!
	private static let xName = "@aiarcheology"
	private static let xURL = URL(string: "twitter://user?screen_name=\(xName)")!
	private static let xWebURL = URL(string: "https://twitter.com/\(xName)")!

	@State private var showCopiedPopover = false

	var body: some View {
		VStack {
			Form {
				Section(header: Text("Application")) {
					HStack(alignment: .center, spacing: 12) {
						if let image = UIImage(named: appIcon){
							Image(uiImage: image)
								.resizable()
								.aspectRatio(contentMode: .fit)
								.clipShape(RoundedRectangle(cornerRadius: 8))
						}
						VStack(alignment: .leading) {
							Text("Version (Beta)")
								.bold()
							Text("v\(versionString)")
						}
						.copiedToClipboard(copiedText: versionString, preview: versionString)
						.foregroundColor(.primary)
					}
					.fixedSize()
					.accessibilityElement(children: .ignore)
					.accessibilityLabel("Version \(versionString)")
				}
				Section(header: Text("Contact")) {
					Button(action: {
						if let url = URL(string: "mailto:\(emailAddress)") {
							UIApplication.shared.open(url)
						}
					}) {
						HStack {
							Image(systemName: "envelope.fill")
							Text(emailAddress)
						}
					}

					HStack {
						Image(systemName: "globe")
							.foregroundColor(.blue)
						Link(Self.websiteURL.absoluteString, destination: Self.websiteURL)
					}

					HStack {
						Image(templateName: "Twitter")
							.resizable()
							.scaledToFit()
							.frame(maxWidth: 16, maxHeight: 16)
							.foregroundColor(.primary)
						Link(Self.xName, destination: Self.xWebURL)
					}
				}
			}
			Text("In the places of forgotten memories, we see not just a pile of rocks, but the resilient people who once arranged them, often under dramatic circumstances, in the right spot.")
				.font(.headline)
				.italic()
				.centerInParentView()
		}
		.navigationBarTitle("About", displayMode: .inline)
	}

	static func appVersion(in bundle: Bundle = .main) -> String {
		guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
			fatalError("CFBundleShortVersionString should not be missing from info dictionary")
		}
		return version
	}
}


extension View {
	func copiedToClipboard(copiedText: String, preview: String) -> some View {
		self.modifier(CopiedToClipboardModifier(copiedText: copiedText, preview: preview))
	}
}
struct CopiedToClipboardModifier: ViewModifier {
	@State private var showPopover = false
	var copiedText: String
	var preview: String

	func body(content: Content) -> some View {
		content
			.onLongPressGesture(minimumDuration: 0.5, pressing: { isPressing in
				if isPressing {
						// Begin of the gesture
				} else {
						// End of the gesture
					UIPasteboard.general.string = copiedText
					self.showPopover = true
					DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
						self.showPopover = false
					}
				}
			}) {
					// This block is empty to allow the gesture to coexist with others
			}
			.popover(isPresented: $showPopover) {
				Text("Copied: \(preview)")
					.padding()
			}
	}
}
