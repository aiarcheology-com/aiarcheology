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
/// Wraps the real app (`content`) once the user is signed in and entitled. Runs
/// the initial session check on appear and re-validates on every foreground so a
/// Dashboard ban / de-entitlement is caught within one refresh.
struct AuthGateView<Content: View>: View {
    @ObservedObject var authState: AuthState
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            switch authState.gate {
            case .checkingSession:
                AuthLoadingView()
            case .signedOut:
                SignInGateView(authState: authState)
            case .locked:
                LockedView(authState: authState)
            case .offline:
                AuthUnavailableView(authState: authState)
            case .ready:
                content()
            }
        }
        .task { await authState.start() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await authState.refresh() }
        }
        .background {
            // Real-auth only: keep the gate in sync with Clerk's session so that a
            // sign-out done out-of-band (e.g. inside the embedded UserProfileView)
            // immediately drops the user back to the gate. The mock path has no Clerk
            // environment, so this observer is omitted there.
            if DependencyContainer.shared.usesMockAuth == false {
                ClerkSessionWatcher(authState: authState)
            }
        }
    }
}

// MARK: - Clerk session sync

/// Invisible observer that refreshes the gate whenever Clerk's signed-in user changes
/// (sign-in, sign-out, or account switch) from anywhere in the app.
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

    /// Real Clerk-backed auth vs. the DEBUG mock. The mock path has no configured Clerk
    /// instance, so the Clerk-dependent `AuthView` is built (and presented) only on the
    /// real-auth path.
    private var usesRealAuth: Bool { DependencyContainer.shared.usesMockAuth == false }

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
                        Task { await ClerkAuthProvider.switchEnvironment(to: newEnv) }
                    }
                    .accessibilityLabel(Text(L10n.Auth.Environment.title))
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
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
            }
        }
    }
}

// MARK: - Locked (signed in, not entitled)

/// Shown when the user is signed in but not on the access allowlist.
private struct LockedView: View {
    @ObservedObject var authState: AuthState
    @State private var showDeleteConfirmation = false
    @State private var deleteFailed = false

    var body: some View {
        AuthMessageView(
            systemImage: "lock.fill",
            title: L10n.Auth.Locked.title,
            message: L10n.Auth.Locked.message
        ) {
            VStack(spacing: 12) {
                Button {
                    Task { await authState.signOut() }
                } label: {
                    Text(L10n.Auth.signOut).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .testability(Testability.Button.authLockedSignOut)

                // A locked user has created an account, so per Apple Guideline
                // 5.1.1(v) they must be able to delete it without first reaching
                // the gated app (where the Settings delete button lives).
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Text(L10n.Auth.Account.Delete.action).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .confirmationDialog(
            L10n.Auth.Account.Delete.title,
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.Auth.Account.Delete.action, role: .destructive) {
                Task {
                    do {
                        try await authState.deleteAccount()
                    } catch {
                        // Don't silently drop the failure (see ios/AGENTS.md §5): log it
                        // and tell the user, since they remain signed in / locked.
                        LoggingPolicy.error("Account deletion failed: \(error.localizedDescription)", logger: .state)
                        deleteFailed = true
                    }
                }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Auth.Account.Delete.message)
        }
        .alert(L10n.Alert.Error.title, isPresented: $deleteFailed) {
            Button(L10n.Common.ok, role: .cancel) {}
        } message: {
            Text(L10n.Alert.Error.unexpected)
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
