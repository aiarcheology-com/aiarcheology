//
//  AppDescriptionView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct AppDescriptionView: View {
    /// Remote About-screen messages (AIA-0115). Injected once at the app root; observed directly
    /// because a nested `ObservableObject` does not republish through `AppState`.
    @EnvironmentObject private var messageCenter: MessageCenterState
    /// Device language for localized message content.
    private let languageCode = AppMessage.deviceLanguageCode
    let versionString: String = appVersion()
    let buildString: String = appBuild()
    let appIcon: String = Bundle.main.iconFileName ?? "AppIcon"
    let emailAddress: String = SupportRequest.supportEmailAddress
    // swiftlint:disable force_unwrapping
    private static let websiteURL = URL(string: "https://www.aiarcheology.com")!
    private static let xName = "@aiarcheology"
    private static let xURL = URL(string: "twitter://user?screen_name=\(xName)")!
    private static let xWebURL = URL(string: "https://twitter.com/\(xName)")!
    // swiftlint:enable force_unwrapping

	var body: some View {
		VStack {
			Form {
				// Remotely-delivered informational messages targeted at the About screen, shown
				// inline above the app info — only when the server actually delivered some.
				if !messageCenter.aboutMessages.isEmpty {
					messagesSection
				}
				applicationSection
				contactSection
				legalSection
			}
			Spacer()
			Text(L10n.About.copyright)
				.foregroundColor(.gray)
				.padding()
		}
		.sheetDismissButton(testability: .appDescriptionDismiss)
		.navigationBarTitle(L10n.Settings.about, displayMode: .inline)
	}

	private var messagesSection: some View {
		Section {
			ForEach(messageCenter.aboutMessages, id: \.id) { message in
				AppMessageInlineRow(
					message: message,
					languageCode: languageCode,
					testabilityLabel: .appMessageAboutRow
				)
			}
		}
	}

	private var applicationSection: some View {
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
	}

	private var contactSection: some View {
		Section(header: Text(L10n.About.Section.contact)) {
			// The structured route (AIA-0440): a category and the technical details make the
			// difference between a triageable inbox and "it doesn't work". Deliberately NOT gated
			// on `isSupportReportingEnabled` — that flag exists to silence the screenshot prompt,
			// not to take away the support form.
			NavigationLink(destination: SupportSettingsView()) {
				HStack {
					Image(systemName: "exclamationmark.bubble.fill")
					Text(L10n.Support.title)
				}
			}
			.testability(Testability.NavigationLink.appDescriptionReportProblem)

			Button(action: { Task { @MainActor in await composeSupportEmail() } }) {
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
	}

	private var legalSection: some View {
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

	/// Opens the system mail composer pre-filled with app/device diagnostics.
	@MainActor
	private func composeSupportEmail() async {
		let subject = "MLBrowser: v" + versionString +
		" on " + DeviceInfo.deviceModelName() +
		" " + UIDevice.current.systemVersion
		let body = await DeviceInfo.information()

		// URLComponents encodes the subject/body with the correct query-component
		// rules; `.urlPathAllowed` leaves reserved characters like & and = intact
		// and corrupts the resulting mailto link.
		var components = URLComponents()
		components.scheme = "mailto"
		components.path = emailAddress
		components.queryItems = [
			URLQueryItem(name: "subject", value: subject),
			URLQueryItem(name: "body", value: body)
		]

		guard let emailURL = components.url else { return }

		// canOpenURL is synchronous, but open(_:) is async in iOS 17+
		if UIApplication.shared.canOpenURL(emailURL) {
			await UIApplication.shared.open(emailURL)
		}
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
