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
        // `overlayPreferenceValue` rather than `overlay`, so the telemetry gate — a descendant of
        // this modifier — can say whether it is currently asking, and this question can hold rather
        // than draw over it (AIA-0763).
        //
        // One question at a time. This modifier is applied at the scene root, an ancestor of the
        // telemetry question, so without this it wins the z-order and lands on top of it, which is
        // exactly what the report shows. Holding rather than reordering the two keeps the gate's own
        // state machine untouched: nothing about *when* telemetry consent is asked changes, only
        // whether this question may share the screen with it.
        //
        // Holding is not dropping. `sync.backupConsentRequest` stays set until it is answered, so
        // the question reappears the moment the telemetry one is dealt with — the same "waits behind
        // whatever has the floor" behaviour this overlay already had for sheets.
        content.overlayPreferenceValue(ConsentQuestionOnScreenKey.self) { isTelemetryQuestionOnScreen in
            if let request = sync.backupConsentRequest, isTelemetryQuestionOnScreen == false {
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

/// The back-up question, drawn as a ``ConsentCard`` — the same view type as the telemetry question,
/// which is what AIA-0763 asked for. The card treatment itself is unchanged; it simply moved into
/// the shared type so the other question could adopt it too.
private struct BackupConsentCard: View {
    let count: Int
    /// Answered exactly once; the coordinator clears the request before acting, so a double tap on
    /// the two buttons cannot record two different answers.
    let answer: (Bool) -> Void

    var body: some View {
        ConsentCard(
            systemImage: "icloud.and.arrow.up",
            title: L10n.Findings.Sync.Backup.title,
            message: L10n.Findings.Sync.Backup.message(count),
            primaryTitle: L10n.Findings.Sync.Backup.confirm,
            primaryIdentifier: Testability.Button.backupConsentConfirm,
            primaryAction: { answer(true) },
            // "Keep on This Device", not "Not Now". The old label made two promises the code does
            // not keep: that the app would ask again (it would not -- AIA-740), and that
            // declining stops back-up generally (it does not; findings created while signed in
            // are the account's by construction and still upload). The label now says only what
            // the button actually does, to these findings. The general off switch is AIA-744.
            secondaryTitle: L10n.Findings.Sync.Backup.keepOnDevice,
            secondaryIdentifier: Testability.Button.backupConsentDecline,
            secondaryAction: { answer(false) }
        )
    }
}
