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
/// The dev/prod instance picker the old root screen had is gone from shipping builds: the backend
/// is fixed at build time (AIA-0791). A Debug build still offers it — see the `#if DEBUG` block.
struct SignInSheet: View {
	@ObservedObject var authState: AuthState

	@State private var authPresented = false
	#if DEBUG
	@State private var debugEnvironment: BackendEnvironment = BackendEnvironment.current
	#endif
	@Environment(\.dismiss) private var dismiss

	/// Real Clerk-backed auth vs. the DEBUG mock, from the composition root (AIA-0385). The mock
	/// path has no configured Clerk instance, so the Clerk-dependent `AuthView` is built (and
	/// presented) only on the real-auth path.
	@Environment(\.usesRealAuth) private var usesRealAuth

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

					#if DEBUG
					// Debug builds only, so it cannot ship. Drives the single value both the Clerk
					// key and the findings Worker read, so the pair cannot come apart (AIA-0791).
					// The Release-visible switch this replaces wrote a `UserDefaults` value that
					// only one half of the pair ever read.
					//
					// `usesRealAuth` is kept from the code this replaces: on the mock path Clerk is
					// never configured, and reconfiguring it there is meaningless.
					if usesRealAuth {
						Picker(L10n.Auth.Environment.title, selection: $debugEnvironment) {
							Text(L10n.Auth.Environment.development).tag(BackendEnvironment.development)
							Text(L10n.Auth.Environment.production).tag(BackendEnvironment.production)
						}
						.pickerStyle(.segmented)
						.onChange(of: debugEnvironment) { _, newEnvironment in
							Task { await switchBackend(to: newEnvironment) }
						}
						.accessibilityLabel(Text(L10n.Auth.Environment.title))
					}
					#endif
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

	#if DEBUG
	/// Delegates to the one operation that moves both halves of the pair. The view never assigns
	/// `BackendEnvironment.override` itself — it cannot, the setter is `private(set)` — because an
	/// assignment would move the Worker while Clerk stayed on the other instance, which is exactly
	/// the mismatched pair this ticket exists to make unrepresentable.
	@MainActor
	private func switchBackend(to newEnvironment: BackendEnvironment) async {
		_ = await BackendEnvironment.switch(to: newEnvironment)
		// Re-sync from the truth after EVERY switch, not only a refused one. Two taps in quick
		// succession run two of these concurrently: the second is refused while the first is still
		// awaiting Clerk, and only the first's completion knows the final environment. An
		// on-failure-only resync would leave the picker showing the refused tap's value.
		debugEnvironment = BackendEnvironment.current
	}
	#endif
}
