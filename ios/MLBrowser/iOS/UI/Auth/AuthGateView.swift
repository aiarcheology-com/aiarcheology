//
//  AuthGateView.swift
//  AI Archeology
//
//  Root authentication gate (AIA-0340). Sits between app-ready and `ContentView`.
//

import SwiftUI
import UIKit
import OSLog
import ClerkKit
import ClerkKitUI

/// Routes the app to the correct root screen based on ``AuthState/gate``.
///
/// Wraps the real app (`content`) once the user is signed in and entitled.
///
/// Does **not** drive ``AuthState`` — that moved to ``AuthLifecycleModifier`` at the app root
/// (AIA-0536). This view only decides what to render, so the paywall-first cut-over can remove it
/// without taking the session check, the foreground re-validation, or Clerk's out-of-band sign-out
/// observer with it.
struct AuthGateView<Content: View>: View {
    @ObservedObject var authState: AuthState
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch authState.gate {
        case .checkingSession:
            AuthLoadingView()
        case .signedOut:
            SignInGateView(authState: authState)
        case .offline:
            AuthUnavailableView(authState: authState)
        case .ready:
            content()
        }
    }
}

// MARK: - Checking session

/// Brief loading state while the persisted session is validated.
private struct AuthLoadingView: View {
    var body: some View {
        ProgressView(L10n.Auth.checking)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Signed out

/// Branded landing screen. Presents the prebuilt Clerk `AuthView` (all enabled
/// providers: email, phone, Google, Facebook, Apple) and advances the gate once
/// the user is signed in.
private struct SignInGateView: View {
    @ObservedObject var authState: AuthState
    @State private var authPresented = false
    @State private var clerkEnv: ClerkEnvironment = ClerkAuthProvider.selectedEnvironment

    /// Real Clerk-backed auth vs. the DEBUG mock, from the composition root (AIA-0385). The mock
    /// path has no configured Clerk instance, so the Clerk-dependent `AuthView` is built (and
    /// presented) only on the real-auth path.
    @Environment(\.usesRealAuth) private var usesRealAuth

    /// Whether to offer the dev/prod instance switch here. Non-App-Store (dev + TestFlight)
    /// real-auth builds only, so testers can pick the instance BEFORE signing in (no need
    /// to sign into dev first). Hidden on the App Store (always production).
    private var showEnvironmentSwitch: Bool {
        usesRealAuth && AppEnvironment.isAppStoreDistribution == false
    }

    var body: some View {
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
                Text(L10n.Auth.SignIn.tagline)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 16) {
                Button {
                    // Only present the Clerk sheet on the real-auth path; on the mock path
                    // there is no `AuthView` to show (avoids a blank modal).
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
                .accessibilityHint(Text(L10n.Auth.SignIn.tagline))
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
                        // Re-sync from the persisted value: `switchEnvironment` only persists
                        // on success (e.g. it no-ops if the target instance's key is missing),
                        // so without this the segmented control could show an instance Clerk
                        // isn't actually pointed at.
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
        // Cap width so the button + switch aren't full-bleed on iPad/macOS; the outer
        // frame centers the capped block.
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $authPresented, onDismiss: {
            // Re-evaluate the gate after the sheet closes — covers both a completed
            // sign-in (→ ready/locked) and a cancel (→ stays signed-out). Avoids
            // observing `Clerk.shared`, which the mock/UI-test path never configures.
            Task { await authState.refresh() }
        }) {
            if usesRealAuth {
                AuthView()
                    .environment(Clerk.shared)
                    .environment(\.clerkTheme, .app)
            }
        }
    }
}

// MARK: - Offline (validation unreachable)

/// Shown when the session could not be validated because the server is unreachable.
/// v1 fails closed: the app requires a connection at launch/foreground.
private struct AuthUnavailableView: View {
    @ObservedObject var authState: AuthState

    var body: some View {
        AuthMessageView(
            systemImage: "wifi.slash",
            title: L10n.Auth.Offline.title,
            message: L10n.Auth.Offline.message
        ) {
            Button {
                Task { await authState.refresh() }
            } label: {
                Text(L10n.Auth.Offline.retry)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .testability(Testability.Button.authOfflineRetry)
        }
    }
}

// MARK: - Shared message layout

/// Centered icon + title + message with a trailing action button.
private struct AuthMessageView<Action: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2).bold()
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            action()
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
