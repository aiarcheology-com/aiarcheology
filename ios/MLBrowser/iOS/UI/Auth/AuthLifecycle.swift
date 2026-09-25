//
//  AuthLifecycle.swift
//  AI Archeology
//
//  The view half of driving `AuthState` (AIA-0536); the process half is `AppRuntime` (AIA-0970).
//

import SwiftUI
import ClerkKit

/// The view half of driving ``AuthState``: on the real-auth path, Clerk's own session observer plus
/// the Clerk environment that observer needs.
///
/// The initial session check and the re-validation on every foreground moved to ``AppRuntime``
/// (AIA-0970), so the headless build drives auth exactly as the app does. The observer stays here:
/// it follows Clerk through the SwiftUI environment, and a headless process has no session for it to
/// watch until programmatic sign-in exists.
///
/// It must mount **once**, at a root that never swaps. Attached to a view that can be swapped, it
/// would be torn down with it — and dropping the Clerk environment would silently disable the
/// out-of-band sign-out observer while everything still compiled and mostly worked. Applied above
/// the gates, so nothing below can unmount it.
struct AuthLifecycleModifier: ViewModifier {
	@ObservedObject var authState: AuthState
	@Environment(\.usesRealAuth) private var usesRealAuth

	func body(content: Content) -> some View {
		content
			.background {
				// Real-auth only: keep auth in sync with Clerk's session so a sign-out done
				// out-of-band (e.g. inside the embedded UserProfileView) is noticed immediately. The
				// mock path has no Clerk environment, so this observer is omitted there.
				if usesRealAuth {
					ClerkSessionWatcher(authState: authState)
				}
			}
	}
}

extension View {
	/// Attach the Clerk session observer. Must be applied **once**, at a root that never unmounts.
	func authLifecycle(_ authState: AuthState) -> some View {
		modifier(AuthLifecycleModifier(authState: authState))
	}
}

/// Invisible observer that refreshes auth whenever Clerk's signed-in user changes (sign-in,
/// sign-out, or account switch) from anywhere in the app.
///
/// Requires the Clerk environment to be injected above it — which is why the injection and this
/// observer must be rehomed together. Separating them leaves the watcher mounted and inert.
private struct ClerkSessionWatcher: View {
	@ObservedObject var authState: AuthState
	@Environment(Clerk.self) private var clerk

	var body: some View {
		Color.clear
			.onChange(of: clerk.user?.id) { _, _ in
				Task { await authState.refresh() }
			}
	}
}
