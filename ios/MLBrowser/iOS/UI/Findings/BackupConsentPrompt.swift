//
//  BackupConsentPrompt.swift
//  AI Archeology
//
//  Asking, once, before a finding leaves the device (AIA-727).
//

import SwiftUI

extension View {
    /// Presents the back-up question wherever the user happens to be.
    ///
    /// It lives at the scene root rather than on the findings list. The list was the obvious home and
    /// the wrong one: a user who never opens it is never asked, and their findings stay on the device
    /// with nothing saying why. The question is about work the user has already done, so it should not
    /// depend on them visiting a particular screen to hear it.
    func backupConsentPrompt(_ sync: FindingsSyncCoordinator) -> some View {
        modifier(BackupConsentPrompt(sync: sync))
    }
}

/// An **overlay**, deliberately not an `.alert` — for the same reason `AnalyticsChoiceGate` and
/// `sharedFindingPresentation` are overlays, and this modifier hits it harder than either.
///
/// The question is raised by a sync cycle, and the cycle that raises it for the first time is almost
/// always the one signing in triggers — so the `SignInSheet` is still on screen when it fires. This
/// view sits at the scene root, an ancestor of that sheet, and UIKit refuses to present an alert from
/// a controller that is already presenting one: *"Attempt to present PlatformAlertController … which
/// is already presenting"*. SwiftUI logs it and drops it; the binding stays true and nothing tries
/// again. The user is never asked, so nothing is ever uploaded, which is precisely what AIA-733's
/// manual test found.
///
/// An overlay has no such rule. It renders behind whatever sheet has the floor and is simply there
/// when that sheet closes — finishing sign-in and *then* being asked is the right sequence anyway.
private struct BackupConsentPrompt: ViewModifier {
    @ObservedObject var sync: FindingsSyncCoordinator

    func body(content: Content) -> some View {
        content.overlay {
            if let request = sync.backupConsentRequest {
                BackupConsentCard(count: request.count) { accepted in
                    // Explicitly discarded: the returned task is for tests to await, and letting it
                    // be the closure's result trips generic inference on the shipping Xcode.
                    _ = sync.answerBackupConsent(accepted: accepted)
                }
                .transition(.opacity)
            }
        }
    }
}

/// The dimmed backdrop and the card on it, shaped like `SharedFindingCard` so the two questions the
/// app can raise over any screen look like the same kind of thing.
private struct BackupConsentCard: View {
    let count: Int
    /// Answered exactly once; the coordinator clears the request before acting, so a double tap on
    /// the two buttons cannot record two different answers.
    let answer: (Bool) -> Void

    var body: some View {
        ZStack {
            // Not tappable to dismiss. Declining is a recorded decision that stops the outbox
            // re-deriving these findings and asking again -- too consequential for a stray tap on the
            // dim. The two buttons are the only exits, and both are always on screen.
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(L10n.Findings.Sync.Backup.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(L10n.Findings.Sync.Backup.message(count))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button(L10n.Findings.Sync.Backup.confirm) { answer(true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .testability(Testability.Button.backupConsentConfirm)
                // "Keep on This Device", not "Not Now". The old label made two promises the code does
                // not keep: that the app would ask again (it would not -- AIA-740), and that
                // declining stops back-up generally (it does not; findings created while signed in
                // are the account's by construction and still upload). The label now says only what
                // the button actually does, to these findings. The general off switch is AIA-744.
                Button(L10n.Findings.Sync.Backup.keepOnDevice) { answer(false) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .testability(Testability.Button.backupConsentDecline)
            }
            .padding(28)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(radius: 24, y: 8)
            .padding(24)
        }
        // Without this VoiceOver walks straight through the dim into the screen behind it.
        .accessibilityAddTraits(.isModal)
    }
}
