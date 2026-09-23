//
//  DeleteAccountView.swift
//  AI Archeology
//
//  Account deletion reached from the account sheet's root, one row under Sign out (AIA-0891).
//

import SwiftUI

/// The destination behind the `Delete account` row this app injects into Clerk's profile.
///
/// **Why this screen exists at all.** Deletion already worked before AIA-0891 — Clerk renders its
/// own delete section inside `UserProfileSecurityView`, four levels down at
/// Settings → Account → Manage account → Security. App Review did not find it and rejected the
/// build under Guideline 5.1.1(v), which is fair: nobody looks for account deletion under
/// "Security". Clerk 1.5.1 offers no way to move, hide, or relabel that built-in section, so the
/// fix is a second, shallower path to the same outcome rather than a relocation of the first.
///
/// **Why a pushed screen rather than a button.** `UserProfileCustomRow` carries a `route`, not a
/// closure: Clerk pushes the route onto the navigation path and the host resolves it. A row that
/// merely opened a confirmation dialog is therefore not expressible. That is not a loss — Clerk's
/// own delete affordance is likewise a screen carrying an explanation and then a confirmation, and
/// a destructive action deserves the extra beat.
///
/// **Why there is no Export First… here, where the hard wall has one.** The wall offers it because
/// the wall is a dead end: Settings, and with it the findings inventory, sits behind the gate, so
/// somebody deleting from there has no route back to their work and the export is their only one
/// (AIA-0779). Here the opposite holds — the user is already inside Settings, one Back tap from the
/// findings list, and deletion does not touch the device copy at all. Offering to rescue data that
/// is not going anywhere reads as a warning: *if they survive, why am I being told to export them?*
/// Both surfaces here state plainly that settings and findings stay on the device, which is the
/// reassurance the wall's export button is a substitute for.
///
/// That is also why neither surface uses `PaywallAccountDeletionPrompt`'s composed message: it ends
/// "and you can export them first", a promise this screen deliberately does not make. The sentence
/// it *does* owe is ``L10n/Auth/Account/Delete/deviceNote``, shared by ``footerText`` and
/// ``confirmationMessage`` so the screen and the dialog covering it cannot say different things.
struct DeleteAccountView: View {
	/// Runs the deletion. `AuthState.deleteAccount()` owns the ordering that matters — purge the
	/// cloud copy first, delete the account second — because the session token is the only
	/// credential that can reach the remaining data (AIA-0816).
	@ObservedObject var authState: AuthState

	@Environment(\.openURL) private var openURL

	@State private var showConfirmation = false

	@State private var failure: AlertItem?

	/// True from the moment Delete is confirmed until the attempt resolves.
	///
	/// A second tap would otherwise start a second `deleteAccount()` over the first, and the two
	/// would race through the purge with only the loser left to report a session that no longer
	/// exists — a failure alert on top of a deletion that actually succeeded.
	///
	/// Nothing clears it on success, which is deliberate: the sheet is being dismissed underneath,
	/// and re-enabling a destructive button on a screen that is going away invites the tap that
	/// arrives just before it does.
	///
	/// That leans on the dismissal actually happening, so: reaching this screen at all requires
	/// `.validated` (the row Settings pushes from is gated on it), and `setSignedOut()` moves the
	/// context off `.validated` and onto `.anonymous`, which is a change `SettingsForm`'s
	/// `onChange` observes with a non-empty path. The one shape that would strand a disabled button
	/// — already `.anonymous` while standing here, so the write publishes nothing — cannot be
	/// reached: the same `onChange` would have dismissed the sheet when it first turned.
	@State private var isDeleting = false

	/// What the screen says under the button, and the tail of what the confirmation says.
	///
	/// Two keys rather than one sentence written twice. ``L10n/Auth/Account/Delete/deviceNote`` is
	/// owed by both surfaces — the screen, and the dialog that covers it — and a dialog is the last
	/// thing a reader sees before an irreversible tap, so it cannot be the one place the
	/// reassurance is missing. Sharing the key is what stops the two drifting, in 17 locales.
	///
	/// `…delete.footer` replaces the old `auth.account.deleteFooter`, which said deletion removes
	/// "all associated data" — true of the account and its cloud back-up, false of the copy on this
	/// device, which is the thing a reader here most wants to know and the reason no export is
	/// offered below. A new key rather than a new value, because all 17 locales carried a faithful
	/// translation of the old meaning and editing in place would have left every non-English reader
	/// holding it (AGENTS §8).
	/// Joined with a paragraph break, not a space. A space between two sentences is an English
	/// typographic convention: `zh-Hans`, `zh-Hant` and `zh-HK` end a sentence with `。`, which
	/// already carries its own trailing space, so an ASCII space after it renders as a stray gap.
	/// A break is correct in every locale and matches how the confirmation composes the same key.
	private static var footerText: String {
		L10n.Auth.Account.Delete.footer + "\n\n" + L10n.Auth.Account.Delete.deviceNote
	}

	/// The billing warning plus the same device note, as separate paragraphs.
	///
	/// Composed here rather than reusing ``PaywallAccountDeletionPrompt``: that type's message ends
	/// "and you can export them first", a promise this screen deliberately does not make — see the
	/// type doc above.
	private static var confirmationMessage: String {
		L10n.Auth.Account.Delete.messageBilling + "\n\n" + L10n.Auth.Account.Delete.deviceNote
	}

	var body: some View {
		List {
			Section(footer: Text(Self.footerText)) {
				HStack {
					Button(role: .destructive) {
						showConfirmation = true
					} label: {
						Text(L10n.Auth.Account.Delete.action)
					}
					.disabled(isDeleting)
					.testability(Testability.Button.settingsDeleteAccount)

					Spacer()

					// Always in the tree and only faded, never inserted or removed. Structural churn
					// on a row is what AIA-0448 forbids, and this screen sits on the stack the
					// findings share sheet is presented from.
					ProgressView()
						.opacity(isDeleting ? 1 : 0)
						.accessibilityHidden(true)
				}
			}
		}
		.navigationTitle(L10n.Auth.Account.Delete.action)
		.navigationBarTitleDisplayMode(.inline)
		// Manage Subscription is `.default` rather than `.cancel` so it cannot collide with the
		// Cancel role, and it is a `Button` opening the URL rather than a `Link`: iOS documents that
		// a confirmation dialog omits any action whose label is not `Text` (AIA-0528).
		.confirmationDialog(
			L10n.Auth.Account.Delete.title,
			isPresented: $showConfirmation,
			titleVisibility: .visible
		) {
			Button(L10n.Paywall.manage) {
				openURL(.appleManageSubscriptions)
			}
			.testability(Testability.Button.settingsDeleteAccountManage)

			Button(L10n.Auth.Account.Delete.action, role: .destructive) {
				delete()
			}
			.testability(Testability.Button.settingsDeleteAccountConfirm)

			Button(L10n.Common.cancel, role: .cancel) {}
		} message: {
			// Unconditional, where the wall's equivalent appears only when findings exist: this
			// screen says the same thing whether or not anything is saved, because "your settings
			// stay" is true either way and a reader mid-deletion should not have to infer it.
			Text(Self.confirmationMessage)
		}
		.alert(item: $failure) { item in
			Alert(title: item.title, message: item.message, dismissButton: item.dismissButton)
		}
	}

	/// The copy for a failed deletion. The stage picks the sentence because the two stages leave
	/// the cloud copy in different states (AIA-0816). After `.purge` the erase is incomplete —
	/// some objects may already be gone — so the purge sentence hedges. After `.accountDeletion`
	/// the purge finished and only the account survives. `cloudDataErased: false` is a build with
	/// nothing to erase, which says so rather than borrowing the purge hedge.
	static func deletionFailureMessage(for failure: AccountDeletionFailure) -> String {
		switch failure {
		case .purge: L10n.Auth.Account.Delete.failedPurge
		case .accountDeletion(_, cloudDataErased: true): L10n.Auth.Account.Delete.failedDeletion
		case .accountDeletion(_, cloudDataErased: false): L10n.Auth.Account.Delete.failedNothingErased
		}
	}

	/// Deletes the account and says which half failed when one does.
	///
	/// Nothing here dismisses on success, deliberately: `deleteAccount()` ends signed out, and
	/// `SettingsForm` already closes the whole sheet when `effectiveContext` turns `.anonymous`
	/// with a non-empty account path (AIA-0536). A dismissal of our own would race that one.
	private func delete() {
		guard isDeleting.not else { return }
		isDeleting = true
		Task {
			do {
				try await authState.deleteAccount()
			} catch let failure as AccountDeletionFailure {
				// The stage picks the copy because the two stages leave the cloud copy in different
				// states (AIA-0816). After `.purge` the erase is *incomplete* — some objects may
				// already be gone, which is why `failedPurge` says "may already have been removed"
				// rather than claiming nothing happened; after `.accountDeletion` the purge finished
				// and only the account itself survives. `.accountDeletion(cloudDataErased: false)`
				// is the third state: a build with nothing to erase, which says so outright rather
				// than borrowing the purge copy's hedge. `AuthState` has already reported the
				// failure at `.error` with the stage named, so nothing is logged again here.
				let message = Self.deletionFailureMessage(for: failure)
				// Cleared on each failure path and on none of the success path: the account still
				// exists here and the copy tells the user to try again, so the button they are
				// told to press has to come back.
				isDeleting = false
				self.failure = AlertItem(
					title: Text(L10n.Alert.Error.title),
					message: Text(message),
					dismissButton: .default(Text(L10n.Common.ok))
				)
			} catch {
				// Unreachable while `deleteAccount()` wraps both stages, and kept so that a future
				// throw added outside them still says something rather than nothing.
				LoggingPolicy.error("Account deletion failed: \(error.localizedDescription)", logger: .state)
				isDeleting = false
				self.failure = AlertItem(
					title: Text(L10n.Alert.Error.title),
					message: Text(L10n.Alert.Error.unexpected),
					dismissButton: .default(Text(L10n.Common.ok))
				)
			}
		}
	}
}
