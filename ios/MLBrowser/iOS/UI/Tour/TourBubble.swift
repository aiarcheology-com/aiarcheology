//
//  TourBubble.swift
//  AI Archeology
//
//  AIA-0333: interactive onboarding spotlight tour — coach-mark bubble.
//

import SwiftUI

/// The coach-mark speech bubble: localized copy, an always-present **Skip**, and a
/// conditional **Next** (shown immediately for scripted steps, after the timeout for
/// user-action steps).
struct TourBubble: View {
	let text: String
	/// Title of the primary (advance) button — "Next" for most steps, "Done" for the last.
	var nextTitle: String = L10n.Tour.next
	let showsNext: Bool
	let onNext: () -> Void
	let onSkip: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(text)
				.font(.callout)
				.foregroundStyle(.primary)
				.fixedSize(horizontal: false, vertical: true)
				// Identify the bubble on the text, not the container — labelling the whole
				// VStack collapses the Skip/Next buttons into one accessibility element and
				// hides them from XCUITest.
				.testability(Testability.View.tourBubble)

			HStack {
				Button(L10n.Tour.skip, action: onSkip)
					.foregroundColor(.blue)
					.testability(Testability.Button.tourSkip)

				Spacer()

				if showsNext {
					Button(nextTitle, action: onNext)
						.fontWeight(.bold)
						.foregroundColor(.green)
						.testability(Testability.Button.tourNext)
				}
			}
		}
		.padding(16)
		.frame(maxWidth: 300)
		.background(
			RoundedRectangle(cornerRadius: 14)
				.fill(.regularMaterial)
				.shadow(radius: 8)
		)
	}
}
