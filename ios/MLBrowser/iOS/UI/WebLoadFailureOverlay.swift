//
//  WebLoadFailureOverlay.swift
//  AI Archeology
//
//  AIA-0509: the page failed to load and automatic recovery is exhausted — tell the user and give
//  them a way out, instead of leaving a blank web view with no explanation.
//

import SwiftUI

struct WebLoadFailureOverlay: View {
	let failure: WebLoadFailure
	let onRetry: () -> Void

	var body: some View {
		ZStack {
			// Opaque: the web view behind is blank or stale, and showing it through would read
			// as a rendering glitch rather than a reported failure.
			Color(.systemBackground)
				.ignoresSafeArea()

			VStack(spacing: 16) {
				Image(systemName: "wifi.exclamationmark")
					.font(.system(size: 44))
					.foregroundStyle(.secondary)
					.accessibilityHidden(true)

				Text(title)
					.font(.headline)
					.multilineTextAlignment(.center)

				Text(message)
					.font(.subheadline)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)

				if let retryURL = failure.retryURL {
					Text(retryURL.absoluteString)
						.font(.caption)
						.foregroundStyle(.tertiary)
						.lineLimit(1)
						.truncationMode(.middle)
				}

				Button(action: onRetry) {
					Text(L10n.Browser.Load.retry)
						.frame(minWidth: 140)
				}
				.buttonStyle(.borderedProminent)
				.accessibilityIdentifier("web.load.retry")
				.accessibilityHint(message)
			}
			.padding(32)
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(title)
	}

	private var title: String {
		switch failure.kind {
		case .unreachable:
			return L10n.Browser.Load.Error.title
		}
	}

	private var message: String {
		switch failure.kind {
		case .unreachable:
			return L10n.Browser.Load.Error.message
		}
	}
}
