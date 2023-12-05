//
//  SettingsView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 28.11.23.
//

	import SwiftUI

struct AlertItem: Identifiable {
	var id = UUID()
	var title: Text
	var message: Text?
	var primaryButton: Alert.Button?
	var dismissButton: Alert.Button?
	var secondaryButton: Alert.Button?
}

	struct SettingsForm: View {
		@Environment(\.dismiss) private var dismiss
		@EnvironmentObject var settings: Settings
		@EnvironmentObject var guide: Guide
		@State private var defaultWebPlaceholder: String = "www.google.com"
		@State private var validationErrorMessage: String?
		@State private var resetButtonColor: Color = .red
		@State private var cleanCacheButtonColor: Color = .red
		@State private var alertItem: AlertItem?

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
								.toolbar {
									ToolbarItemGroup(placement: .keyboard) {
										Spacer()
										Button("Done") {
											Self.removeFocus()
										}
									}
								}
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
						NavigationLink(destination: SlideshowView().environmentObject(settings)) {
							HStack {
								Text("Introduction")
							}
						}
						HStack {
							Text("Restore Defaults")
							Spacer()
							Button(action: {
								self.alertItem = AlertItem(title: Text("Warning"), 
														   message: Text("Resetting the application will erase all data models from the ML Browser except the demo models. Are you sure you want to proceed?"),
														   primaryButton: .destructive(Text("Restore"), action: guide.resetApplication),
														   secondaryButton: .cancel())
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
						self.alertItem = AlertItem(title: Text("Error"), 
												 message: Text(validationErrorMessage ?? ""), //TODO optional
												 dismissButton: .default(Text("OK"), action: { validationErrorMessage = nil }))
					} catch {
						validationErrorMessage = "An unexpected error occurred."
						self.alertItem = AlertItem(title: Text("Error"), 
												  message: Text(validationErrorMessage ?? ""), //TODO optional
												  dismissButton: .default(Text("OK"), action: { validationErrorMessage = nil }))
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
				.onChange(of: mergedObservable) { _ in
					resetButtonColor = .red
				}
				.alert(item: $alertItem) { alertItem in
					if let primaryButton = alertItem.primaryButton, let secondaryButton = alertItem.secondaryButton {
						return Alert(title: alertItem.title,
									 message: alertItem.message,
									 primaryButton: primaryButton,
									 secondaryButton: secondaryButton)
					}
					if let dismissButton = alertItem.dismissButton {
						return Alert(title: alertItem.title,
									 message: alertItem.message,
									 dismissButton: dismissButton)
					}
					return Alert(title: alertItem.title,
								 message: alertItem.message)
				}
			}
		}
	}

struct AppDescriptionView: View {
	let versionString: String = appVersion()
	let buildString: String = appBuild()
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
						let version = "v\(versionString) \(buildString)"
						VStack(alignment: .leading) {
							Text("Version")
								.bold()
							Text(version)
						}
						.copiedToClipboard(copiedText: version, preview: version)
						.foregroundColor(.primary)
					}
					.fixedSize()
					.accessibilityElement(children: .ignore)
					.accessibilityLabel("Version \(versionString)")
				}
				Section(header: Text("Contact")) {
					Button(action: {
						let email = emailAddress
						let subject = "MLBrowser: v" + versionString +
									  " on " + DeviceInfo.deviceModelName() +
									  " " + UIDevice.current.systemVersion
						let body = DeviceInfo.information()


						guard let emailURL = URL(string: "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")&body=\(body.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")") else { return }

							if UIApplication.shared.canOpenURL(emailURL as URL) {
								UIApplication.shared.open(emailURL as URL)
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
			Text("In the places of forgotten memories, we should see not just piles of rocks, but also the resilient people -  builders - who once arranged these rocks in the right spot.")
				.multilineTextAlignment(.center)
				.font(.headline)
				.italic()
				.centerInParentView()
				.frame(maxHeight: 200)
				.padding(25)
			Spacer()
			Text("Copyright © 2023 by Vladimír Slavík, AI Archeology")
				.foregroundColor(.gray)
				.padding()
		}
		.navigationBarTitle("About", displayMode: .inline)
	}

	static func appVersion(in bundle: Bundle = .main) -> String {
		guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
			assert(false, "CFBundleShortVersionString should not be missing from info dictionary")
			return ""
		}
		return version
	}
	static func appBuild(in bundle: Bundle = .main) -> String {
		guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
			assert(false, "CFBundleVersion should not be missing from info dictionary")
			return ""
		}
		return build
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
			WebHistoryEntry.deleteAll(in: moc, executeAndMerge: true)
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

struct DeviceInfo {
	static func information() -> String {
		let device = UIDevice.current
		let deviceModel = DeviceInfo.deviceModelName()
		let iosVersion = device.systemVersion

		let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown"
		let appVersionNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
		let appBuildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"

		let storageStatus = getDeviceStorageStatus()
		
		let date = getCurrentFormattedDate()

		let info = """
			Device Model: \(deviceModel)
			iOS Version: \(iosVersion)
			App Name: \(appName)
			App Version Number: \(appVersionNumber)
			App Build Number: \(appBuildNumber)
			Current Device Storage Status: \(storageStatus)
			Info Gathered to Date: \(date)
		"""

		return info
	}

	static func getDeviceStorageStatus() -> String {
		let fileManager = FileManager.default
		do {
			let attributes = try fileManager.attributesOfFileSystem(forPath: NSHomeDirectory())
			let freeSpace = attributes[.systemFreeSize] as? NSNumber
			let totalSpace = attributes[.systemSize] as? NSNumber

			let freeSpaceGB = (freeSpace?.doubleValue ?? 0.0) / 1_000_000_000
			let totalSpaceGB = (totalSpace?.doubleValue ?? 0.0) / 1_000_000_000

			return "Free: \(String(format: "%.2f", freeSpaceGB)) GB, Total: \(String(format: "%.2f", totalSpaceGB)) GB"
		} catch {
			return "Storage information could not be retrieved"
		}
	}

	static func getCurrentFormattedDate() -> String {
		let dateFormatter = DateFormatter()
		dateFormatter.dateStyle = .medium
		dateFormatter.timeStyle = .short

		let currentDate = Date()
		return dateFormatter.string(from: currentDate)
	}

	static func deviceModelName() -> String {
		var systemInfo = utsname()
		uname(&systemInfo)

		let machineMirror = Mirror(reflecting: systemInfo.machine)
		let identifier = machineMirror.children.reduce("") { identifier, element in
			guard let value = element.value as? Int8, value != 0 else { return identifier }
			return identifier + String(UnicodeScalar(UInt8(value)))
		}

		return identifier
	}
}
