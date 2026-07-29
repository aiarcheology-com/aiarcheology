//
//  AuthLifecycle.swift
//  AI Archeology
//
//  Owns driving `AuthState`, independently of who renders because of it (AIA-0536).
//

import SwiftUI
import UIKit
import ClerkKit

/// Drives ``AuthState``: the initial session check, re-validation on every foreground, and — on the
/// real-auth path only — Clerk's own session observer plus the Clerk environment that observer needs.
///
/// These four belong together and belong at a root that mounts **once**. They used to live on
/// `AuthGateView`, which was safe only because that view was the root and never swapped. Under the
/// paywall-first gate order (AIA-0536) auth no longer decides the root, so attaching them to any view
/// that can be swapped would restart the session check on every swap — and dropping the Clerk
/// environment would silently disable the out-of-band sign-out observer while everything still
/// compiled and mostly worked.
///
/// Applied above the gates, so nothing below can unmount it.
struct AuthLifecycleModifier: ViewModifier {
	@ObservedObject var authState: AuthState
	@Environment(\.usesRealAuth) private var usesRealAuth

	func body(content: Content) -> some View {
		content
			.task { await authState.start() }
			.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
				Task { await authState.refresh() }
			}
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
	/// Attach the auth lifecycle. Must be applied **once**, at a root that never unmounts.
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
