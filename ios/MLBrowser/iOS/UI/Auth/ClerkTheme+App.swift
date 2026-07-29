//
//  ClerkTheme+App.swift
//  AI Archeology
//
//  App-matched theme for Clerk's prebuilt screens.
//

import SwiftUI
import ClerkKit
import ClerkKitUI

extension ClerkTheme {
	/// App-matched theme for Clerk's prebuilt screens (`AuthView`, `UserProfileView`) so they read as
	/// part of AI Archeology rather than Clerk's default styling. Clerk only exposes palette / font /
	/// corner-radius tokens — the screens' layout (avatar header, row structure, "Secured by Clerk"
	/// footer) is fixed and can't be made into a native grouped `Form`.
	///
	/// Lives in its own file rather than beside the auth gate (AIA-0536): `SettingsView` depends on
	/// it, and the gate that used to host it is being dismantled by the paywall-first cut-over. A
	/// definition that outlives its neighbours should not sit inside one of them.
	@MainActor
	static let app = ClerkTheme(
		colors: .init(
			primary: .green,                          // matches the app's green primary action
			background: Color(uiColor: .systemBackground),
			danger: .red,
			foreground: .primary,
			primaryForeground: .white                 // label/icon on the green primary button
		),
		design: .init(borderRadius: 10)               // ~iOS inset-grouped cell radius
	)
}
