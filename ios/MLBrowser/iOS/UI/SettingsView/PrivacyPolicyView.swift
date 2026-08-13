//
//  PrivacyPolicyView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI
import WebKit

/// Shows a bundled HTML document — today only the privacy policy, from the paywall and from
/// Settings → About.
///
/// **It renders in a web view, and that is the fix rather than a preference** (AIA-0616). This
/// used to convert the document with `NSAttributedString(documentType: .html)` and hand the result
/// to a SwiftUI `Text`, which produced a **blank sheet**: the conversion itself was fine — 14 308
/// characters of correct text — but the caller then ran
/// `setAttributes(AttributeContainer([.foregroundColor: Color.primary]))`, which *replaces* every
/// attribute in the string rather than merging, and stored a SwiftUI `Color` under a UIKit key that
/// expects a `UIColor`. The type mismatch is invisible to the compiler, so the text was laid out
/// and drawn in nothing.
///
/// Fixing that one line would have restored visibility and still been wrong. The policy is authored
/// as a styled page: a stylesheet, a three-column sharing table, links, and a
/// `prefers-color-scheme: dark` block. `NSAttributedString`'s importer discards the stylesheet,
/// mangles the table, and blocks the main thread parsing 15 KB. A web view shows the document as
/// written, in both appearances, for free.
///
/// This matters beyond tidiness: Paid Applications Agreement Schedule 2 §3.8(b) requires a
/// **functional** link to the privacy policy inside the app, and it is on the paywall — the screen
/// App Review reads most carefully. A blank page there is a rejection.
struct PrivacyPolicyView: View {
	var htmlFileName: String

	var body: some View {
		if let url = Bundle.main.url(forResource: htmlFileName, withExtension: "html"),
		   let html = try? String(contentsOf: url, encoding: .utf8) {
			// The base URL is the document's own directory, so anything it ever references relatively
			// resolves. Nothing does today; it costs nothing and removes a trap from the next edit.
			BundledHTMLView(html: html, baseURL: url.deletingLastPathComponent())
		} else {
			ScrollView {
				Text(L10n.About.privacyNotAvailable)
					.padding()
			}
		}
	}
}

/// A `WKWebView` that renders one in-bundle HTML string and sends taps on links to the system.
private struct BundledHTMLView: UIViewRepresentable {
	let html: String
	let baseURL: URL

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeUIView(context: Context) -> WKWebView {
		let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
		webView.navigationDelegate = context.coordinator
		// Transparent, so the document's own background — white or black, per its
		// `prefers-color-scheme` block — is what shows, with no second background fighting it.
		webView.isOpaque = false
		webView.backgroundColor = .clear
		webView.scrollView.backgroundColor = .clear
		return webView
	}

	func updateUIView(_ webView: WKWebView, context: Context) {
		// Load once. `updateUIView` runs on every SwiftUI update, and reloading there would restart
		// the document — and throw away the reader's scroll position — each time an unrelated piece
		// of state changed while this sheet was open.
		guard context.coordinator.loadedHTML != html else { return }
		context.coordinator.loadedHTML = html
		webView.loadHTMLString(html, baseURL: baseURL)
	}

	final class Coordinator: NSObject, WKNavigationDelegate {
		var loadedHTML: String?

		/// Keeps the sheet on the policy and hands every tapped link to the system.
		///
		/// The document links out to Apple, Clerk, Sentry, TelemetryDeck and a `mailto:` address.
		/// Navigating those *inside* this sheet would turn a legal document into an unaccountable
		/// mini-browser with no address bar and no way back — and `mailto:` would simply fail.
		/// Only `.linkActivated` is cancelled, so the initial `loadHTMLString` still runs.
		func webView(
			_ webView: WKWebView,
			decidePolicyFor navigationAction: WKNavigationAction,
			decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
		) {
			guard navigationAction.navigationType == .linkActivated,
				  let url = navigationAction.request.url else {
				decisionHandler(.allow)
				return
			}
			decisionHandler(.cancel)
			Task { @MainActor in
				await UIApplication.shared.open(url)
			}
		}
	}
}
