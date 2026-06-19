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
    @Environment(Clerk.self) private var clerk
    @State private var authPresented = false

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

            Button {
                authPresented = true
            } label: {
                Text(L10n.Auth.SignIn.button)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
            .accessibilityHint(Text(L10n.Auth.SignIn.tagline))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $authPresented) {
            AuthView()
        }
        .onOpenURL { url in
            Task { try? await clerk.handle(url) }
        }
        .onChange(of: clerk.user?.id) { _, newValue in
            guard newValue != nil else { return }
            authPresented = false
            Task { await authState.didCompleteSignIn() }
        }
    }
}

// MARK: - Locked (signed in, not entitled)

/// Shown when the user is signed in but not on the access allowlist.
private struct LockedView: View {
    @ObservedObject var authState: AuthState

    var body: some View {
        AuthMessageView(
            systemImage: "lock.fill",
            title: L10n.Auth.Locked.title,
            message: L10n.Auth.Locked.message
        ) {
            Button {
                Task { await authState.signOut() }
            } label: {
                Text(L10n.Auth.signOut).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
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
