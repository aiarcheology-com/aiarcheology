//
//  ProductionBannerWindow.swift
//  AI Archeology
//
//  "You are pointed at production" — for the whole runtime, on every screen (AIA-0791).
//

#if DEBUG
import UIKit
import SwiftUI
import ClerkKit

/// A passthrough overlay window carrying a red strip whenever a Debug build is pointed at the
/// production backend.
///
/// A window rather than a view modifier because the warning has to survive `.sheet` and
/// `.fullScreenCover` — every destructive action in the app (account deletion, Remove All
/// Findings, sign-out) is presented that way, so a root-view banner would disappear at exactly
/// the moment it matters.
///
/// `#if DEBUG` is the gate rather than any distribution-channel inference: requirement 2 of
/// AIA-0791 forbids introducing new receipt or provisioning-profile inference, and neither can be
/// verified for an iOS-app-on-Mac Xcode run. Xcode's Run action is Debug on simulator, device and
/// Mac alike, which is the case this is for. A local *Release* build shows no banner; see the
/// accepted-risk register in the plan.
@MainActor
enum ProductionBannerWindow {

    private static var windows: [ObjectIdentifier: UIWindow] = [:]

    /// Whether the app is on the mock-auth path, handed in at `install()`.
    ///
    /// Passed in rather than read from `DependencyContainer.shared`: only the app entry point and the
    /// background-session app delegate may touch that singleton (`DependencyContainer.swift:19-22`),
    /// and this window's content is built outside the app's environment tree, so it cannot read
    /// `\.usesRealAuth` either. `install()` is called from the app entry point, which may.
    private static var usesMockAuth = false

    /// Call once, at app launch. Idempotent per scene.
    ///
    /// The observers deliberately ignore the `Notification` payload and re-walk
    /// `connectedScenes` instead. Reading `notification.object` from the block is a Swift 6
    /// data-race error (`Notification` is not `Sendable`), and `update()` already covers every
    /// scene — including the one that just connected.
    ///
    /// All three notifications are observed and none alone is sufficient: `install()` runs from
    /// the app's initialiser (`MLBrowser.init`), before any scene exists, so the launch-time `update()` below sees
    /// an empty `connectedScenes`; a scene is not guaranteed to be in `connectedScenes` yet when
    /// `willConnect` is posted, so `didActivate` is the one that certainly catches it; and
    /// `didDisconnect` is what lets `update()` release a closed window's scene.
    static func install(usesMockAuth: Bool) {
        Self.usesMockAuth = usesMockAuth
        for name in [
            UIScene.willConnectNotification,
            UIScene.didActivateNotification,
            UIScene.didDisconnectNotification
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { update() }
            }
        }
        update()
    }

    /// Re-evaluates every scene. Called at launch and after `BackendEnvironment.switch(to:)`.
    ///
    /// Without this the banner would only ever reflect the environment at *scene connect* — a
    /// picker flip to production would show nothing, and a flip back would leave a stale red
    /// strip claiming production while the app talked to staging.
    static func update() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // Drop windows belonging to scenes that have gone away. `attach(to:)` only ever adds, so
        // without this a closed iPad window's `UIWindow` would be retained for the lifetime of the
        // process — and its scene with it.
        let live = Set(scenes.map(ObjectIdentifier.init))
        for key in windows.keys where live.contains(key) == false {
            windows[key]?.isHidden = true
            windows.removeValue(forKey: key)
        }
        for scene in scenes {
            attach(to: scene)
        }
    }

    /// One window per scene: iPad multiwindow, Mac and external displays each get their own, and a
    /// single window would warn on only one of them.
    private static func attach(to scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard BackendEnvironment.current == .production else {
            // Tear down rather than merely skipping, so a switch back to development clears it.
            windows[key]?.isHidden = true
            windows.removeValue(forKey: key)
            return
        }
        guard windows[key] == nil else { return }

        let window = UIWindow(windowScene: scene)
        // Above alerts and confirmation dialogs, which present in their own alert-level window.
        window.windowLevel = .alert + 1
        // Passthrough: without this the strip eats taps, including status-bar tap-to-scroll.
        window.isUserInteractionEnabled = false
        window.backgroundColor = .clear
        window.rootViewController = UIHostingController(
            rootView: ProductionBanner(usesMockAuth: usesMockAuth)
        )
        window.rootViewController?.view.backgroundColor = .clear
        // Never makeKeyAndVisible: that would steal key-window and keyboard focus from the app.
        window.isHidden = false
        windows[key] = window
    }
}

private struct ProductionBanner: View {
    let usesMockAuth: Bool

    var body: some View {
        VStack {
            Text(verbatim: "PRODUCTION — \(accountLabel)")
                .font(.caption2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(.red)
                .foregroundStyle(.white)
            Spacer()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The Clerk **user id**, truncated — never the email address. A full-runtime overlay is in
    /// every screen recording, demo and bug-report screenshot, which makes it more exposed than
    /// the share card `ClerkAuthProvider.nameUnlessItIsAnAddress` exists to protect.
    ///
    /// `Clerk.shared` is touched **only** on the real-auth path: the mock-auth path deliberately
    /// never calls `ClerkAuthProvider.configure()` (`MLBrowser.swift`), and reading `Clerk.shared`
    /// when Clerk was never configured **traps with SIGILL**. A crash from the safety banner would
    /// be a poor joke.
    private var accountLabel: String {
        guard usesMockAuth == false else { return "mock auth" }
        guard let id = Clerk.shared.user?.id else { return "signed out" }
        return String(id.prefix(8)) + "…"
    }
}
#endif
