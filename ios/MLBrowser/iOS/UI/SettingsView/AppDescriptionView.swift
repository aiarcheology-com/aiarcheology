//
//  AppDescriptionView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct AppDescriptionView: View {
    let versionString: String = appVersion()
    let buildString: String = appBuild()
    let appIcon: String = Bundle.main.iconFileName ?? "AppIcon"
    let emailAddress: String = "info@aiarcheology.com"
    // swiftlint:disable force_unwrapping
    private static let websiteURL = URL(string: "https://www.aiarcheology.com")!
    private static let xName = "@aiarcheology"
    private static let xURL = URL(string: "twitter://user?screen_name=\(xName)")!
    private static let xWebURL = URL(string: "https://twitter.com/\(xName)")!
    // swiftlint:enable force_unwrapping

	@State private var showCopiedPopover = false

	var body: some View {
		VStack {
			Form {
				Section(header: Text(L10n.About.Section.application)) {
					HStack(alignment: .center, spacing: 12) {
						if let image = UIImage(named: appIcon) {
							Image(uiImage: image)
								.resizable()
								.aspectRatio(contentMode: .fit)
								.clipShape(RoundedRectangle(cornerRadius: 8))
						}
						let version = "v\(versionString) \(buildString)"
						VStack(alignment: .leading) {
							Text(L10n.About.version)
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
				Section(header: Text(L10n.About.Section.contact)) {
					Button(action: {
						Task { @MainActor in
							let email = emailAddress
							let subject = "MLBrowser: v" + versionString +
							" on " + DeviceInfo.deviceModelName() +
							" " + UIDevice.current.systemVersion
							let body = await DeviceInfo.information()

							guard let emailURL = URL(string: "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")&body=\(body.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")") else { return }

							// canOpenURL is synchronous, but open(_:) is async in iOS 17+
							if UIApplication.shared.canOpenURL(emailURL) {
								await UIApplication.shared.open(emailURL)
							}
						}
					}) {
						HStack {
							Image(systemName: "envelope.fill")
							Text(emailAddress)
						}
					}
					.testability(Testability.Button.appDescriptionEmailContact)

					HStack {
						Image(systemName: "globe")
							.foregroundColor(.blue)
						Link(Self.websiteURL.absoluteString, destination: Self.websiteURL)
							.testability(Testability.Link.appDescriptionWebsite)
					}

					HStack {
						Image(templateName: "Twitter")
							.resizable()
							.scaledToFit()
							.frame(maxWidth: 20, maxHeight: 19)
							.foregroundColor(.primary)
						Link(Self.xName, destination: Self.xWebURL)
							.testability(Testability.Link.appDescriptionTwitter)
					}
				}
				Section(header: Text(L10n.About.Section.legal)) {
					NavigationLink(destination:
									PrivacyPolicyView(htmlFileName: "privacypolicy")
						.navigationTitle(L10n.About.privacyPolicy)
					) {
						Text(L10n.About.privacyPolicy)
					}
					.testability(Testability.NavigationLink.appDescriptionPrivacyPolicy)
				}
			}
			Spacer()
			Text("Copyright © 2023 by Vladimír Slavík, AI Archeology")
				.foregroundColor(.gray)
				.padding()
		}
		.sheetDismissButton(testability: .appDescriptionDismiss)
		.navigationBarTitle(L10n.Settings.about, displayMode: .inline)
	}

	static func appVersion() -> String {
		guard let version = AppEnvironment.shortVersion else {
			assert(false, "CFBundleShortVersionString should not be missing from info dictionary")
			return ""
		}
		return version
	}
	static func appBuild() -> String {
		guard let build = AppEnvironment.buildNumber else {
			assert(false, "CFBundleVersion should not be missing from info dictionary")
			return ""
		}
		return build
	}
}
