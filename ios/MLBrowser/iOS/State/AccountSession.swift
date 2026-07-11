//
//  AccountSession.swift
//  AI Archeology
//
//  AIA-0390: the identity + commerce feature grouped into one injectable, independently-testable
//  session. Owns the derived auth/subscription state (each wrapping a provider) and is built by
//  `DependencyContainer.makeAppState()`; `AppState` forwards `authState`/`subscriptionState` to it.
//

import Foundation

@MainActor
final class AccountSession {
	// MARK: - Injected providers (owned by DependencyContainer).
	//
	// INVARIANT (AIA-0390): `init` stores injected refs ONLY — never touches a `lazy var` below.
	private let authProvider: AuthProviding
	private let subscriptionProvider: SubscriptionProviding

	// MARK: - Owned account feature state (lazy → forced on first access, exactly as before).
	lazy var authState = AuthState(provider: self.authProvider)
	lazy var subscriptionState = SubscriptionState(provider: self.subscriptionProvider)

	init(authProvider: AuthProviding, subscriptionProvider: SubscriptionProviding) {
		self.authProvider = authProvider
		self.subscriptionProvider = subscriptionProvider
	}
}
