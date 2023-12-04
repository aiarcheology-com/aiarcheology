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
		@State private var cleanCacheButtonColor: Color = .red
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
						Toggle("Reopen Last Page", isOn: $settings.reopenLastPage)
						HStack {
							Text("History Limit")
								.foregroundColor(.primary)
							Spacer()
							TextField("0-100", value: $settings.historySize, formatter:
										NumberFormatter.historyLimitFormatter)
								.multilineTextAlignment(.trailing)
								.keyboardType(.numberPad)
								.foregroundColor(.gray)
						}
						NavigationLink(destination: BrowserHistoryView()) {
							HStack {
								Text("History")
							}
						}
						HStack {
							Text("Delete Cache")
							Spacer()
							Button(action: {
								WebCacheCleaner.clean()
								cleanCacheButtonColor = .blue
							}) {
								Text("Delete")
									.bold()
									.foregroundColor(cleanCacheButtonColor)
							}
						}
						.onChange(of: settings.applicationResetButtonToggle) { reseted in
							resetButtonColor = .blue
						}
					}
					Section(header: Text("ML Browser")) {
						NavigationLink(destination: AppDescriptionView()) {
							HStack {
								Text("About")
							}
						}
						NavigationLink(destination: AppDescriptionView()) {
							HStack {
								Text("Help")
							}
						}
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
			Spacer()
			Text("In the places of forgotten memories, we see not just piles of rocks, but also the resilient people who once arranged them in the right spot.")
				.multilineTextAlignment(.center)
				.font(.headline)
				.italic()
				.centerInParentView()
				.frame(maxHeight: 200)
			Spacer()
			Text("Copyright © 2023 by Vladimír Slavík, AI Archeology")
				.foregroundColor(.gray)
				.padding()
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
			.onLongPressGesture(minimumDuration: 1.0, pressing: { isPressing in
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

struct BrowserHistoryView: View {
	@Environment(\.managedObjectContext) var moc
	@Environment(\.presentationMode) var presentation
	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \WebHistoryEntry.creationDate_, ascending: false)],
		predicate: NSPredicate(format: "entityId != nil AND page != nil AND creationDate_ != nil"),
		animation: .default)
	private var history: FetchedResults<WebHistoryEntry>
	@State private var refreshFrom: Bool = false // TODO: history is not being reloaded after deletion

	var body: some View {
		VStack {
			Form {
				List {
					ForEach(history, id: \.self) { (item: WebHistoryEntry) in
						let page = item.page?.absoluteString ?? "Unknown Page"
						Text(page)
							.swipeActions {
								Button(action: {
									UIPasteboard.general.string = page
								}) {
									Label("COPY", systemImage: "doc.on.doc")
								}
								.tint(.blue) // Optional: customize the button color

								Button(role: .destructive, action: {
									guard let entityId = item.entityId else {
										assert(false, "No entry has been found after the selection.")
										return
									}
									WebHistoryEntry.delete(entityId, in: moc)
								}) {
									Label("DELETE", systemImage: "trash")
								}
							}
					}
				}
			}
		}
		.navigationTitle("Browsing History")
		.navigationBarItems(trailing: Button(action: {
			WebHistoryEntry.deleteAll(in: moc)
			refreshFrom.toggle()
			self.presentation.wrappedValue.dismiss()
		}) {
			Text("Clear").bold()
				.foregroundColor(refreshFrom.disabled ? .red : .blue)
		}
		)
	}
}

extension NumberFormatter {
	static var historyLimitFormatter: NumberFormatter {
		let formatter = NumberFormatter()
		formatter.numberStyle = .none
		formatter.minimum = 0
		formatter.maximum = 100
		return formatter
	}
}
