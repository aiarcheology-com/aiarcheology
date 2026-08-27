//
//  SignInSheet.swift
//  AI Archeology
//
//  Contextual sign-in, presented from anywhere (AIA-0536).
//

import SwiftUI
import ClerkKit
import ClerkKitUI

/// The sign-in surface, as a **presentable sheet** rather than a root screen.
///
/// Under the paywall-first gate order (AIA-0536) signing in is never a precondition for using the
/// app — entitlement is. So this is offered contextually from four places: the paywall (a signed-out
/// lapsed subscriber must be able to reach account recovery and deletion without buying first), the
/// drawer, Settings, and once after a finding is saved.
///
/// Keeps the dev/prod instance picker the old root screen had: testers need to choose the Clerk
/// instance *before* signing in, and there is no other moment to offer it.
struct SignInSheet: View {
	@ObservedObject var authState: AuthState

	@State private var authPresented = false
	@State private var clerkEnv: ClerkEnvironment = ClerkAuthProvider.selectedEnvironment
	@Environment(\.dismiss) private var dismiss

	/// Real Clerk-backed auth vs. the DEBUG mock, from the composition root (AIA-0385). The mock
	/// path has no configured Clerk instance, so the Clerk-dependent `AuthView` is built (and
	/// presented) only on the real-auth path.
	@Environment(\.usesRealAuth) private var usesRealAuth

	/// Offer the dev/prod instance switch on non-App-Store real-auth builds only (dev + TestFlight),
	/// so testers can pick the instance before signing in. Hidden on the App Store (always production).
	private var showEnvironmentSwitch: Bool {
		usesRealAuth && AppEnvironment.isAppStoreDistribution == false
	}

	var body: some View {
		NavigationStack {
			VStack(spacing: 24) {
				Spacer()

				Image("AppLogo")
					.resizable()
					.scaledToFit()
					.frame(maxWidth: 160, maxHeight: 160)
					.accessibilityHidden(true)

				VStack(spacing: 8) {
					Text(L10n.Auth.SignIn.title)
						.font(.title).bold()
						.multilineTextAlignment(.center)
					// Says what signing in *is*, not what it unlocks (AIA-0455). This read
					// "Sign in to detect objects on any website", which was false in both
					// directions: an account does not enable detection, and detection is not
					// gated — the app has been usable signed out since AIA-0536. A sign-in
					// screen claiming to unlock the core feature is precisely what a Guideline
					// 5.1.1(v) review looks for. It stays deliberately plain until the account
					// carries something a user would want (AIA-0615, findings sync).
					Text(L10n.Auth.SignIn.subtitleBackup)
						.font(.body)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
				}
				.padding(.horizontal, 32)

				Spacer()

				VStack(spacing: 16) {
					Button {
						// Only present the Clerk sheet on the real-auth path; on the mock path there
						// is no `AuthView` to show (avoids a blank modal).
						guard usesRealAuth else { return }
						authPresented = true
					} label: {
						Text(L10n.Auth.SignIn.button)
							.fontWeight(.bold)
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.borderedProminent)
					.tint(.green)
					.controlSize(.large)
					.accessibilityHint(Text(L10n.Auth.SignIn.subtitleBackup))
					.testability(Testability.Button.authSignIn)

					if showEnvironmentSwitch {
						// Pick the Clerk instance before signing in. Reconfigures Clerk so the
						// sign-in sheet targets the chosen instance (no session to clear here).
						Picker(L10n.Auth.Environment.title, selection: $clerkEnv) {
							Text(L10n.Auth.Environment.development).tag(ClerkEnvironment.development)
							Text(L10n.Auth.Environment.production).tag(ClerkEnvironment.production)
						}
						.pickerStyle(.segmented)
						.onChange(of: clerkEnv) { _, newEnv in
							// Re-sync from the persisted value: `switchEnvironment` only persists on
							// success (e.g. it no-ops if the target instance's key is missing), so
							// without this the control could show an instance Clerk isn't pointed at.
							Task {
								await ClerkAuthProvider.switchEnvironment(to: newEnv)
								clerkEnv = ClerkAuthProvider.selectedEnvironment
							}
						}
						.accessibilityLabel(Text(L10n.Auth.Environment.title))
					}
				}
				.padding(.horizontal, 32)
				.padding(.bottom, 40)
			}
			// Cap width so the button + switch aren't full-bleed on iPad/macOS.
			.frame(maxWidth: 480)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(L10n.Common.cancel) { dismiss() }
						.testability(Testability.Button.signInSheetCancel)
				}
			}
		}
		.sheet(isPresented: $authPresented, onDismiss: {
			// Re-evaluate after the Clerk sheet closes — covers a completed sign-in and a cancel.
			// Avoids observing `Clerk.shared`, which the mock/UI-test path never configures.
			Task {
				await authState.refresh()
				// Signing in is the whole point of this sheet, so close it once it succeeded.
				// Left open on cancel, where the user may want another try or the env picker.
				if authState.gate == .ready { dismiss() }
			}
		}) {
			if usesRealAuth {
				AuthView()
					.environment(Clerk.shared)
					.environment(\.clerkTheme, .app)
			}
		}
	}
}
