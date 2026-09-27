//
//  HeadlessAccountScreen.swift
//  AI Archeology
//
//  AIA-0974.
//

#if DEBUG
import ClerkKit
import Foundation
import HeadlessKit

/// The account screen over the open menu: sign in while anonymous; once validated, sign out and the
/// findings controls the account's Settings shows. Also the web screen's sign-in offer after the first
/// signed-out save, the same `SignInSheet` with the menu closed.
///
/// Reports only whether an account is signed in and its back-up switch — never the email address or
/// the account id.
@MainActor
struct HeadlessAccountScreen: HeadlessScreen {
	let parts: HeadlessAppParts
	/// Where `close` lands, asked for when the actions are listed: see
	/// `HeadlessRouteDecision.route(afterClosing:)`.
	let closeTarget: @MainActor () -> Route

	var route: Route { "account" }

	/// Upper bound for the gate to settle after Clerk completes the sign-in. The refresh that
	/// follows may coalesce with a pass already in flight, so the action waits for the outcome.
	static let signInSettleTimeout: Duration = .seconds(30)

	/// A validated account is signed in: the gate is ready and names an account. The one definition
	/// behind the screen's state, the action results, `context.auth.signedIn` and `signed-in`.
	static func isSignedIn(_ authState: AuthState) -> Bool {
		authState.gate == .ready && authState.accountIdentifier != nil
	}

	/// The signed-in account, when Settings' back-up switch would show: a validated account and a
	/// build with a Worker. The account travels with the decision, as it does from the switch.
	private var backUpToggleAccount: String? {
		guard Self.isSignedIn(parts.authState), parts.findingsSync.isCloudConfigured else { return nil }
		return parts.authState.accountIdentifier
	}

	func state() -> JSONValue {
		var state: [String: JSONValue] = ["signedIn": .bool(Self.isSignedIn(parts.authState))]
		if backUpToggleAccount != nil {
			state["backUpEnabled"] = .bool(parts.findingsSync.isBackUpEnabled)
		}
		return .object(state)
	}

	func actions() -> [HeadlessAction] {
		let parts = parts
		// The drawer's sheets: the model the drawer view binds to.
		let presentation = parts.chromeState.drawerPresentation
		// The web screen's sign-in offer, the other way this screen is up: the model the web screen binds to.
		let offer = parts.chromeState.saveFindingPresentation
		var actions = [
			HeadlessAction("close", summary: "Close the account screen.", navigatesTo: closeTarget()) { _ in
				presentation.dismissAccount()
				// The offer's `SignInSheet` Cancel.
				offer.dismissSignInOffer()
				return nil
			}
		]
		switch parts.authState.effectiveContext {
		case .anonymous:
			let email = ParameterSpec(
				"email",
				.string,
				summary: "A Clerk test address: <name>+clerk_test@example.com."
			)
			let code = ParameterSpec("code", .string, summary: "The email verification code.")
			// No `navigatesTo`: once signed in, the new account's consent question may take the screen.
			actions.append(HeadlessAction(
				"sign-in",
				summary: "Sign in to a Clerk test account with its email code, creating it if new.",
				parameters: [email, code]
			) { arguments in
				try await Self.signIn(arguments: arguments, parts: parts, presentation: presentation, offer: offer)
			})
		case .validated:
			// No `navigatesTo`: signing out is async and can change whether a back-up question is
			// pending, so the response reports where the app landed.
			actions.append(HeadlessAction("sign-out", summary: "Sign out of the account.") { _ in
				let authState = parts.authState
				// The call the account screen's and the paywall's Sign Out make.
				await authState.signOut()
				// Settings dismisses the account UI on sign-out: the user is done with account things.
				presentation.dismissAccount()
				offer.dismissSignInOffer()
				// `signOut()` publishes `.signedOut` even when Clerk's request failed, because the app
				// must not keep a user in who asked to leave. Automation must not call that a clean
				// sign-out: the session would outlive the run.
				guard authState.isProviderSignedIn == false else {
					throw HeadlessError(.actionFailed, "the app signed out, but Clerk still holds the session")
				}
				return ["signedIn": .bool(Self.isSignedIn(authState))]
			})
			actions.append(contentsOf: signedInFindingsActions())
		case .suspended, .indeterminate:
			// Signing in cannot work offline and the account cannot be shown; only leaving is possible.
			break
		}
		return actions
	}

	/// Settings' findings controls for the signed-in account: the back-up switch and Reset → Remove
	/// Findings. Only while the account is validated, as the account's Settings is.
	private func signedInFindingsActions() -> [HeadlessAction] {
		guard Self.isSignedIn(parts.authState) else { return [] }
		let findingsSync = parts.findingsSync
		let findingRepository = parts.findingRepository
		var actions: [HeadlessAction] = []
		if let account = backUpToggleAccount {
			let enabledParameter = ParameterSpec("enabled", .boolean, summary: "Whether the account backs findings up.")
			actions.append(HeadlessAction(
				"set-backup",
				summary: "Switch backing up on or off, and wait for the sync it starts.",
				parameters: [enabledParameter]
			) { arguments in
				let enabled = try arguments.boolean("enabled")
				// The switch's own call. Nil means no cycle followed: either the coordinator refused the
				// change (the signed-in account moved on) or it applied it while the account's cloud data
				// is being erased, when no sync may run. The switch itself says which.
				if let task = findingsSync.setBackUpEnabled(enabled, expectedAccount: account) {
					await task.value
				} else if findingsSync.isBackUpEnabled != enabled {
					throw HeadlessError(.actionFailed, "the back-up switch was refused: the signed-in account changed")
				}
				return ["backUpEnabled": .bool(findingsSync.isBackUpEnabled)]
			})
		}
		// Returns once the local removal is done, as Settings does: neither starts a sync here.
		actions.append(HeadlessAction(
			"remove-all-findings",
			summary: "Permanently delete every finding on this device and its screenshot."
		) { _ in
			do {
				try await findingRepository.removeAllFindings()
			} catch {
				// Domain and code identify the failure; its message could carry a path.
				let nsError = error as NSError
				throw HeadlessError(.actionFailed, "the findings could not be removed (\(nsError.domain) \(nsError.code))")
			}
			return nil
		})
		return actions
	}

	/// Clerk's own sign-in, then the gate refresh `SignInSheet` runs when Clerk's sheet closes; the
	/// action returns once the app holds a validated account.
	private static func signIn(
		arguments: Arguments,
		parts: HeadlessAppParts,
		presentation: DrawerPresentation,
		offer: SaveFindingPresentation
	) async throws -> JSONValue? {
		// The provider owns every refusal (mock auth, a non-test address, a production backend), so
		// the rules live in one place; `headlessFailure(for:)` only chooses the error code.
		let email = try arguments.string("email")
		let code = try arguments.string("code")
		let authState = parts.authState
		do {
			try await authState.signIn(emailAddress: email, code: code)
		} catch {
			throw headlessFailure(for: error)
		}
		let settled = try await HeadlessWait.until(timeout: signInSettleTimeout) {
			isSignedIn(authState)
		}
		guard settled else {
			throw HeadlessError(
				.timeout,
				"signed in, but the app did not reach a validated account in time (gate: \(authState.gate.headlessName))"
			)
		}
		// `SignInSheet` dismisses itself once the gate is ready, from the menu or as the offer.
		presentation.dismissAccount()
		offer.dismissSignInOffer()
		return ["signedIn": .bool(isSignedIn(authState))]
	}

	/// A sign-in failure a client can act on, with nothing that could carry the address: Clerk's
	/// `message` and `longMessage`, and so any `localizedDescription`, may echo the identifier.
	private static func headlessFailure(for error: Error) -> Error {
		switch error {
		case is HeadlessError, is CancellationError:
			return error
		case let apiError as ClerkAPIError:
			return HeadlessError(.actionFailed, "Clerk refused the sign-in: \(apiError.code)")
		case ProgrammaticSignInError.notATestAddress:
			// The address itself is never echoed.
			return HeadlessError(.invalidArgument, "'email' is not a Clerk test address (<name>+clerk_test@example.com)")
		case ProgrammaticSignInError.unsupported:
			return HeadlessError(.actionFailed, "the app runs on mock auth (no Clerk key in this build); sign-in must reach Clerk")
		case let signInError as ProgrammaticSignInError:
			return HeadlessError(.actionFailed, signInError.errorDescription ?? "the sign-in did not complete")
		default:
			// Domain and code identify the failure without its message.
			let nsError = error as NSError
			return HeadlessError(.actionFailed, "the sign-in failed (\(nsError.domain) \(nsError.code))")
		}
	}
}
#endif
