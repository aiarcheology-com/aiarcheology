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

/// What the drawer's views present from their own `@State`, kept by the headless application
/// instead — the same arrangement as the gates' `hasEverShownContent`.
@MainActor
final class HeadlessPresentation {
	/// The drawer footer's account UI: `SignInSheet` while signed out, the account's Settings once
	/// signed in. Cleared whenever the drawer is not open, because the UI never shows it without one.
	var isAccountPresented = false
}

/// The account screen over the open menu: sign in while anonymous, sign out once validated.
///
/// Reports only whether an account is signed in — never the email address or the account id.
@MainActor
struct HeadlessAccountScreen: HeadlessScreen {
	let appState: AppState
	let presentation: HeadlessPresentation

	var route: Route { "account" }

	/// Upper bound for the gate to settle after Clerk completes the sign-in. The refresh that
	/// follows may coalesce with a pass already in flight, so the action waits for the outcome.
	static let signInSettleTimeout: Duration = .seconds(30)

	/// A validated account is signed in: the gate is ready and names an account. The one definition
	/// behind the screen's state, the action results, `context.auth.signedIn` and `signed-in`.
	static func isSignedIn(_ authState: AuthState) -> Bool {
		authState.gate == .ready && authState.accountIdentifier != nil
	}

	func state() -> JSONValue {
		["signedIn": .bool(Self.isSignedIn(appState.authState))]
	}

	func actions() -> [HeadlessAction] {
		let appState = appState
		let presentation = presentation
		var actions = [
			HeadlessAction("close", summary: "Close the account screen.", navigatesTo: "drawer") { _ in
				presentation.isAccountPresented = false
				return nil
			}
		]
		switch appState.authState.effectiveContext {
		case .anonymous:
			let email = ParameterSpec(
				"email",
				.string,
				summary: "A Clerk test address: the local part must end in +clerk_test."
			)
			let code = ParameterSpec("code", .string, summary: "The email verification code.")
			// No `navigatesTo`: once signed in, the new account's consent question may take the screen.
			actions.append(HeadlessAction(
				"sign-in",
				summary: "Sign in to a Clerk test account with its email code, creating it if new.",
				parameters: [email, code]
			) { arguments in
				try await Self.signIn(arguments: arguments, appState: appState, presentation: presentation)
			})
		case .validated:
			actions.append(HeadlessAction("sign-out", summary: "Sign out of the account.") { _ in
				// The call the account screen's and the paywall's Sign Out make.
				await appState.authState.signOut()
				// Settings dismisses the account UI on sign-out: the user is done with account things.
				presentation.isAccountPresented = false
				return ["signedIn": .bool(Self.isSignedIn(appState.authState))]
			})
		case .suspended, .indeterminate:
			// Signing in cannot work offline and the account cannot be shown; only leaving is possible.
			break
		}
		return actions
	}

	/// Clerk's own sign-in, then the gate refresh `SignInSheet` runs when Clerk's sheet closes; the
	/// action returns once the app holds a validated account.
	private static func signIn(
		arguments: Arguments,
		appState: AppState,
		presentation: HeadlessPresentation
	) async throws -> JSONValue? {
		// Mock auth refuses programmatic sign-in anyway; say why before anything else, so a keyless
		// build fails with its cause rather than a provider error.
		guard appState.usesRealAuth else {
			throw HeadlessError(
				.actionFailed,
				"the app runs on mock auth (no Clerk key in this build); sign-in must reach Clerk"
			)
		}
		let email = try arguments.string("email")
		let code = try arguments.string("code")
		// Checked here too, so the refusal is an argument error. The address is not echoed.
		guard ClerkTestAddress.isValid(email) else {
			throw HeadlessError(
				.invalidArgument,
				"'email' is not a Clerk test address (local part must end in +clerk_test)"
			)
		}
		let authState = appState.authState
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
		// `SignInSheet` dismisses itself once the gate is ready.
		presentation.isAccountPresented = false
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
