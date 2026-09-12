//
//  ConsentCard.swift
//  AI Archeology
//
//  One shape for every question the app raises over any screen (AIA-0763).
//

import SwiftUI

/// The card the app uses to ask the user a two-way question it cannot proceed past.
///
/// **Extracted because the two questions were drawn as two different kinds of thing and could be on
/// screen at once** (AIA-0763). The back-up question was a dimmed card; the telemetry question was a
/// bare full-screen `VStack` with no backdrop of its own. Raised together, the card sat on top of
/// the telemetry screen and the telemetry screen's own icon and buttons showed around its edges —
/// two overlapping questions with no visible boundary between them and no way to tell which pair of
/// buttons belonged to which.
///
/// Sharing the view type is what makes them the same kind of thing rather than merely similar: a
/// later change to the padding, the corner radius or the button styles cannot drift one question
/// away from the other, because there is only one of each.
///
/// The backdrop is deliberately **not** tappable to dismiss. Both questions record a decision that
/// changes what leaves the device, which is too consequential for a stray tap on the dim. The two
/// buttons are the only exits and both are always on screen.
/// Whether a consent question is being asked **in this window** (AIA-0763).
///
/// A preference rather than a flag on `AnalyticsState`, because the answer is per-window and that
/// object is shared by every scene. The app generates its scene manifest with
/// `UIApplicationSupportsMultipleScenes`, so two iPad or Mac windows really can ask at once; a
/// single shared Boolean would have had two writers, and whichever window closed its question first
/// would have released the back-up card over the window still asking.
///
/// It travels the right way, too: `AnalyticsChoiceGate` is a *descendant* of the scene-root modifier
/// that needs to know, and preferences are how a descendant tells an ancestor something.
struct ConsentQuestionOnScreenKey: PreferenceKey {
	static let defaultValue = false

	/// `||`, so a window asking anywhere in its tree counts as asking.
	static func reduce(value: inout Bool, nextValue: () -> Bool) {
		value = value || nextValue()
	}
}

struct ConsentCard: View {
	let systemImage: String
	let title: String
	let message: String

	let primaryTitle: String
	let primaryIdentifier: any TestabilityIdentification
	let primaryAction: () -> Void

	let secondaryTitle: String
	let secondaryIdentifier: any TestabilityIdentification
	let secondaryAction: () -> Void

	/// Whether the buttons have been on screen long enough to be meant.
	///
	/// These two questions can hand over to each other: answering the telemetry one releases the
	/// back-up one, which is the same card in the same place with its buttons at the same points.
	/// A double tap on "Not now" would land its second tap on "Keep on This Device" — and that is a
	/// recorded decline the app never asks again about (AIA-740), taken from a user who never saw
	/// the question. A brief settle closes that window.
	@State private var isAcceptingInput = false

	var body: some View {
		ZStack {
			Color.black.opacity(0.35)
				.ignoresSafeArea()

			// **The card hugs its content, and only scrolls when it cannot.**
			//
			// A bare `ScrollView` is greedy: it takes every point of height offered, so on an iPad
			// the card ran the full window with the buttons stranded at the top above a field of
			// empty white. `ViewThatFits` asks for the plain column first and takes the scrolling
			// one only when that genuinely does not fit — which is what the scrolling is for. The
			// copy is localized into every shipped language and rendered at the user's Dynamic Type
			// size, so this view does not get to know the card's natural height in advance, and a
			// question whose only exits are below the fold is a trap.
			ViewThatFits(in: .vertical) {
				cardBody
				ScrollView {
					cardBody
				}
				.scrollBounceBehavior(.basedOnSize)
			}
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
		// `.allowsHitTesting` rather than `.disabled`: the buttons must not *look* unavailable for
		// the moment they are settling. AIA-0779 was raised precisely because bordered buttons that
		// read as disabled are taken for broken.
		.allowsHitTesting(isAcceptingInput)
		.task {
			try? await Task.sleep(for: .milliseconds(400))
			isAcceptingInput = true
		}
	}

	/// The card's content, built once and offered to `ViewThatFits` in both its plain and its
	/// scrolling form. Shared rather than duplicated so the two candidates cannot drift — they have
	/// to measure the same thing for the choice between them to mean anything.
	private var cardBody: some View {
		VStack(spacing: 16) {
			Image(systemName: systemImage)
				.font(.system(size: 44))
				.foregroundStyle(.tint)
				.accessibilityHidden(true)
			Text(title)
				.font(.title2.bold())
				.multilineTextAlignment(.center)
			Text(message)
				.multilineTextAlignment(.center)
				.foregroundStyle(.secondary)
			Button(primaryTitle, action: primaryAction)
				.buttonStyle(.borderedProminent)
				.controlSize(.large)
				.testability(primaryIdentifier)
			Button(secondaryTitle, action: secondaryAction)
				.buttonStyle(.bordered)
				.controlSize(.large)
				.testability(secondaryIdentifier)
		}
		.padding(28)
		.frame(maxWidth: .infinity)
	}
}
