//
//  SupportSettingsView.swift
//  AI Archeology
//
//  User controls for reporting a problem (AIA-0454).
//

import SwiftUI

/// Settings for the problem-reporting flow, reachable from Settings → About.
///
/// The screenshot toggle deliberately renders an unset preference as enabled: until the user has
/// answered the first offer, screenshot detection is active and will ask for that decision. A
/// change in this screen stores a concrete answer and applies to later screenshots immediately.
struct SupportSettingsView: View {
	@EnvironmentObject private var settings: Settings
	@Environment(\.usesRealAuth) private var usesRealAuth

	@State private var showSupportRequest = false

	var body: some View {
		Form {
			Section {
				Button {
					showSupportRequest = true
				} label: {
					Label(L10n.Support.sendEmail, systemImage: "envelope.fill")
				}
				.testability(Testability.Button.supportSettingsSendEmail)
			}

			Section {
				Toggle(L10n.Support.detectScreenshots, isOn: screenshotDetectionBinding)
					.testability(Testability.Toggle.supportSettingsDetectScreenshots)
			}
		}
		.navigationTitle(L10n.Support.title)
		.navigationBarTitleDisplayMode(.inline)
		.sheet(isPresented: $showSupportRequest) {
			// No category preset: reaching this from Settings says nothing about what is wrong, so
			// the user picks. The environment value is re-injected because custom values do not
			// reliably cross sheets on Mac (Designed for iPad).
			SupportRequestView()
				.environment(\.usesRealAuth, usesRealAuth)
		}
	}

	private var screenshotDetectionBinding: Binding<Bool> {
		Binding(
			get: { settings.screenshotDetectionEnabled ?? true },
			set: { settings.screenshotDetectionEnabled = $0 }
		)
	}
}

#Preview {
	NavigationStack {
		SupportSettingsView()
			.environmentObject(Settings())
	}
}
