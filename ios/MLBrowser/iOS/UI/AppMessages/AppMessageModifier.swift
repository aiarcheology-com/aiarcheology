//
//  AppMessageModifier.swift
//  AI Archeology
//
//  Top-banner presentation of remote in-app messages (AIA-0115).
//

import SwiftUI

/// Presents the currently-owned remote message as a prominent top banner, for the surface that is
/// mounted right now. Attached once at the scene root, *above* the auth / subscription / analytics
/// gates (like ``ScreenshotReportModifier``), so a message can appear over the login and paywall
/// screens too.
///
/// The modifier is deliberately dumb (AGENTS §3): all gating lives in ``MessageCenterState``.
/// ``MessageSurfaceResolver`` maps the launch gates to the mounted ``MessageSurface`` (or `nil`
/// when none is), and the modifier only forwards two intents to the state object for that surface —
/// `drainPendingTap(for:)` then `presentNextIfNeeded(for:)`. It never decides *whether* a message is
/// visible; when the resolver returns `nil` (a loading/offline/consent screen) nothing is presented
/// and no banner renders. The overlay is driven purely by `messageCenter.presented`, so it stays in
/// the view tree while visible (the AIA-0448 hazard cannot apply here).
struct AppMessageModifier: ViewModifier {
	@ObservedObject var messageCenter: MessageCenterState
	@ObservedObject var authState: AuthState
	@ObservedObject var subscriptionState: SubscriptionState
	@ObservedObject var analytics: AnalyticsState

	/// App-ready flag, passed as a value: the scene root re-renders this modifier when it flips
	/// (the body already branches on `appState.isReady`), so it needs no separate observation.
	let isReady: Bool
	/// The language the banner renders localized message content in — mirrors
	/// ``MessageCenterState``'s `languageCode` default.
	let languageCode: String

	/// The surface mounted right now, or `nil` when none is (see ``MessageSurfaceResolver``).
	private var surface: MessageSurface? {
		MessageSurfaceResolver.surface(
			isReady: isReady,
			gate: authState.gate,
			paymentsSurfaceEnabled: subscriptionState.isPaymentsSurfaceEnabled,
			isSubscribed: subscriptionState.isSubscribed,
			// Anything short of resolved counts as pending: a message banner over a consent
			// question, a hold, or a "needs connection" screen is wrong for the same reason.
			analyticsChoicePending: analytics.consentPresentation != .resolved
		)
	}

	func body(content: Content) -> some View {
		content
			.overlay(alignment: .top) {
				// Render only when a surface is mounted: `presented` alone can outlive a transition
				// to a non-messageable screen (offline / consent), and the banner must not show there.
				if surface != nil, let message = messageCenter.presented {
					AppMessageBanner(
						message: message,
						languageCode: languageCode,
						onReply: { messageCenter.recordReply(buttonID: $0) },
						onDismiss: { messageCenter.dismissPresented() }
					)
					.transition(.move(edge: .top).combined(with: .opacity))
				}
			}
			// The implicit spring is disabled under UI tests: applied to the whole scene `content`, its
			// in/out transition keeps the app from ever posting "animations complete", so XCUITest never
			// sees the process go idle and every query on the messaged surface times out. Production is
			// unchanged; the banner simply appears/disappears without the spring under test.
			.animation(AppEnvironment.isRunningUITests ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: messageCenter.presented)
			.onAppear { presentIfPossible() }
			.onChange(of: surface) { _, newSurface in
				// A surface change first evicts a presented message that does not target the new
				// surface (a login-only banner must not ride through sign-in), then presents the
				// new surface's own head.
				if let newSurface {
					messageCenter.reconcilePresented(for: newSurface)
				}
				presentIfPossible()
			}
			.onReceive(messageCenter.objectWillChange) { _ in presentIfPossible() }
			// `objectWillChange` fires on willSet — when a retraction clears the slot, the receive
			// above still observes the *old* non-nil `presented` and no-ops. This fires after the
			// clear commits, so a queued successor presents without waiting for the next trigger.
			.onChange(of: messageCenter.presented) { _, newValue in
				if newValue == nil { presentIfPossible() }
			}
	}

	/// Forwards presentation intents to the state object for the mounted surface. No-ops when no
	/// surface is mounted — the state object owns every visibility decision.
	private func presentIfPossible() {
		guard let surface else { return }
		messageCenter.drainPendingTap(for: surface)
		messageCenter.presentNextIfNeeded(for: surface)
	}
}

/// The banner card: title + body, with a reply-button row for interactive messages and an explicit
/// dismiss for informational ones. Styling mirrors ``TourBubble`` (material card + shadow).
private struct AppMessageBanner: View {
	let message: AppMessage
	let languageCode: String
	let onReply: (String) -> Void
	let onDismiss: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(alignment: .top, spacing: 8) {
				Text(message.localizedTitle(for: languageCode))
					.font(.headline)
					.frame(maxWidth: .infinity, alignment: .leading)
					.testability(Testability.Label.appMessageTitle)

				// Informational messages are dismissed explicitly; interactive ones are dismissed by
				// replying, so they carry no separate close control (dismissing without a reply would
				// only re-present them).
				if !message.isInteractive {
					Button(action: onDismiss) {
						Image(systemName: "xmark.circle.fill")
							.font(.title3)
							.foregroundStyle(.secondary)
					}
					.buttonStyle(.plain)
					.accessibilityLabel(L10n.Common.dismiss)
					.testability(Testability.Button.appMessageDismiss)
				}
			}

			// Long bodies (up to the 4000-char cap) and large Dynamic Type must not push the reply
			// controls off screen: prefer the plain text when it fits, otherwise bound the body and
			// let it scroll, keeping dismiss/reply reachable.
			ViewThatFits(in: .vertical) {
				bodyText
				ScrollView {
					bodyText
				}
				.frame(maxHeight: 220)
			}

			if message.isInteractive {
				// Reply labels run to 60 chars each and translate longer than English, so a fixed
				// row truncates every label once there are three of them. Prefer one row while the
				// labels genuinely fit; otherwise give each button its own full-width line, the way
				// a system alert does.
				ViewThatFits(in: .horizontal) {
					replyRow
					replyStack
				}
				// Trailing alignment lives out here, NOT on `replyRow`: a candidate that accepts any
				// width (a `Spacer`, or `maxWidth: .infinity`) always reports that it fits, and the
				// stack would never be reached.
				.frame(maxWidth: .infinity, alignment: .trailing)
			}
		}
		.padding(16)
		.background(
			// The style tint is a low-opacity wash + hairline over the material, so system colors
			// keep the card legible in both appearances without per-style foreground rules.
			RoundedRectangle(cornerRadius: 14)
				.fill(.regularMaterial)
				.overlay(
					RoundedRectangle(cornerRadius: 14)
						.fill((styleTint ?? .clear).opacity(0.14))
				)
				.overlay(
					RoundedRectangle(cornerRadius: 14)
						.strokeBorder((styleTint ?? .clear).opacity(0.35), lineWidth: 1)
				)
				.shadow(radius: 8)
		)
		.padding(.horizontal, 12)
		.padding(.top, 8)
		.frame(maxWidth: 500)
		// Keep the card a container so its title / dismiss / reply buttons stay individually
		// reachable to VoiceOver and UI tests (a plain label would collapse them).
		.accessibilityElement(children: .contain)
		.testability(Testability.View.appMessageBanner)
	}

	/// The compact candidate: one row, measured at its natural width. Deliberately carries no
	/// `Spacer` and no flexible frame — see the alignment note at the call site.
	private var replyRow: some View {
		HStack(spacing: 12) {
			ForEach(message.buttons, id: \.id) { button in
				replyButton(button)
			}
		}
	}

	/// The fallback: one full-width button per line, in payload order.
	private var replyStack: some View {
		VStack(spacing: 8) {
			ForEach(message.buttons, id: \.id) { button in
				replyButton(button, fillsWidth: true)
			}
		}
	}

	/// `fillsWidth` widens the *label*, not the button: a `.frame` on the `Button` itself only
	/// grows the tap target and leaves the pill centred at its natural width, which reads as a
	/// ragged column rather than the even rows of a system alert.
	private func replyButton(_ button: AppMessage.MessageButton, fillsWidth: Bool = false) -> some View {
		Button {
			onReply(button.id)
		} label: {
			Text(button.label)
				.frame(maxWidth: fillsWidth ? .infinity : nil)
		}
		.buttonStyle(.borderedProminent)
		.testability(Testability.Button.appMessageReply, label: button.id)
	}

	// Inline Markdown (links open through the environment `openURL` — the system browser).
	private var bodyText: some View {
		Text(message.attributedBody(for: languageCode))
			.font(.subheadline)
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
			.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var styleTint: Color? {
		switch message.messageStyle {
		case .info: .blue
		case .warning: .orange
		case .success: .green
		case nil: nil
		}
	}
}

/// One inline message row for the pinned form sections (Settings / About App): title + Markdown
/// body over the message's style wash. Shared so both surfaces render identically.
struct AppMessageInlineRow: View {
	let message: AppMessage
	let languageCode: String
	let testabilityLabel: Testability.Label

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(message.localizedTitle(for: languageCode))
				.font(.headline)
			Text(message.attributedBody(for: languageCode))
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.testability(testabilityLabel, label: message.id)
		.listRowBackground(rowTint)
	}

	/// Style wash for a message row; `nil` keeps the default form row background.
	private var rowTint: Color? {
		switch message.messageStyle {
		case .info: Color.blue.opacity(0.12)
		case .warning: Color.orange.opacity(0.12)
		case .success: Color.green.opacity(0.12)
		case nil: nil
		}
	}
}

// MARK: - Previews

#Preview("Informational") {
	AppMessageBanner(
		message: AppMessage(
			id: "preview-info",
			title: "Welcome to ML Browser",
			body: "Remote messages appear here. This one is informational and can be dismissed.",
			surfaces: [.inApp]
		),
		languageCode: "en",
		onReply: { _ in },
		onDismiss: {}
	)
	.padding(.top, 40)
}

#Preview("Styled + Markdown") {
	AppMessageBanner(
		message: AppMessage(
			id: "preview-styled",
			title: "Heads up",
			body: "Bodies support **inline Markdown** — see [the docs](https://example.com) for details.",
			surfaces: [.inApp],
			style: "warning"
		),
		languageCode: "en",
		onReply: { _ in },
		onDismiss: {}
	)
	.padding(.top, 40)
}

#Preview("Interactive") {
	AppMessageBanner(
		message: AppMessage(
			id: "preview-interactive",
			title: "Enjoying the app?",
			body: "Interactive messages carry reply buttons; the choice lands on the user's account.",
			surfaces: [.inApp],
			buttons: [
				AppMessage.MessageButton(id: "yes", label: "Yes"),
				AppMessage.MessageButton(id: "no", label: "Not really")
			]
		),
		languageCode: "en",
		onReply: { _ in },
		onDismiss: {}
	)
	.padding(.top, 40)
}

extension View {
	/// Presents remote in-app messages as a top banner for the mounted surface. See
	/// ``AppMessageModifier``. Attach at the scene root, above the auth/subscription/analytics gates.
	func appMessageBanner(
		messageCenter: MessageCenterState,
		authState: AuthState,
		subscriptionState: SubscriptionState,
		analytics: AnalyticsState,
		isReady: Bool,
		languageCode: String = AppMessage.deviceLanguageCode
	) -> some View {
		modifier(AppMessageModifier(
			messageCenter: messageCenter,
			authState: authState,
			subscriptionState: subscriptionState,
			analytics: analytics,
			isReady: isReady,
			languageCode: languageCode
		))
	}
}
