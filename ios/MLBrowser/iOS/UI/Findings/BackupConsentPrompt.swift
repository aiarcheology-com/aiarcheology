//
//  BackupConsentPrompt.swift
//  AI Archeology
//
//  Asking, once, before a finding leaves the device (AIA-727).
//

import SwiftUI

/// Presents the back-up question wherever the user happens to be.
///
/// It lives at the scene root rather than on the findings list. The list was the obvious home and
/// the wrong one: a user who never opens it is never asked, and their findings stay on the device
/// with nothing saying why. The question is about work the user has already done, so it should not
/// depend on them visiting a particular screen to hear it.
private struct BackupConsentPrompt: ViewModifier {
    @ObservedObject var sync: FindingsSyncCoordinator

    func body(content: Content) -> some View {
        content.alert(
            L10n.Findings.Sync.Backup.title,
            isPresented: Binding(
                get: { sync.backupConsentRequest != nil },
                // Answering is idempotent -- the coordinator clears the request before acting -- so
                // this dismissal cannot race the button the user actually pressed.
                set: { if $0 == false { sync.answerBackupConsent(accepted: false) } }
            )
        ) {
            Button(L10n.Findings.Sync.Backup.confirm) { sync.answerBackupConsent(accepted: true) }
            Button(L10n.Findings.Sync.Backup.decline, role: .cancel) {
                sync.answerBackupConsent(accepted: false)
            }
        } message: {
            Text(L10n.Findings.Sync.Backup.message(sync.backupConsentRequest?.count ?? 0))
        }
    }
}

extension View {
    func backupConsentPrompt(_ sync: FindingsSyncCoordinator) -> some View {
        modifier(BackupConsentPrompt(sync: sync))
    }
}
