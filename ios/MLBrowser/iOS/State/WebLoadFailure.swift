//
//  WebLoadFailure.swift
//  AI Archeology
//
//  AIA-0509: the user-facing classification of a web load failure.
//

import Foundation

/// A load failure worth showing the user, with the URL a retry should target.
///
/// Deliberately carries a `kind`, not a pre-localized message: localization is presentation, so
/// the overlay maps `kind` → `L10n` (`ios/AGENTS.md` — state holds logic, views render).
struct WebLoadFailure: Equatable {
	enum Kind: Equatable {
		/// The page could not be reached: offline, timed out, host/DNS failure.
		case unreachable
	}

	let kind: Kind
	/// Where a retry should go. `nil` when the error carried no failing URL and the web view had
	/// none either — the overlay then retries whatever the web view currently holds.
	let retryURL: URL?

	/// Decides whether a navigation error should be **shown to the user**.
	///
	/// This is an **allowlist**, and the distinction from `webViewLoadErrorLevel(for:)` is
	/// load-bearing rather than stylistic. That function (`WebScreen.swift`) is a *log-level*
	/// decision — a denylist that downgrades exactly `NSURLErrorCancelled` and reports everything
	/// else to Sentry (AIA-0296). Reusing it here would surface an overlay for cases where the
	/// page is perfectly fine and the user merely tapped something WebKit will not render:
	///
	/// - `WebKitErrorDomain` 102 ("frame load interrupted"), which is what WKWebView delivers for a
	///   non-renderable MIME type or a download — and `MLWebView` implements neither
	///   `decidePolicyFor navigationResponse` nor `WKDownloadDelegate`, so *every* attachment link
	///   takes that path.
	/// - `NSURLErrorUnsupportedURL` (-1002) for `mailto:` / `tel:` / app-scheme links.
	///
	/// So this allowlists only the reachability family AIA-0509 is about and returns `nil` for
	/// everything else. The two classifiers are intentionally NOT unified; a drift guard in
	/// `WebLoadFailureTests` asserts that anything shown here is also something Sentry sees.
	static func classify(_ error: Error) -> WebLoadFailure? {
		let nsError = error as NSError
		guard nsError.domain == NSURLErrorDomain, reachabilityCodes.contains(nsError.code) else {
			return nil
		}
		let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
		return WebLoadFailure(kind: .unreachable, retryURL: failingURL)
	}

	/// The reachability family: offline, timed out, cannot connect to host, cannot find host,
	/// network connection lost. Everything outside this set is either benign (a superseded load,
	/// an unrenderable scheme) or not something a "Try Again" button can fix.
	private static let reachabilityCodes: Set<Int> = [
		NSURLErrorNotConnectedToInternet,   // -1009
		NSURLErrorTimedOut,                 // -1001
		NSURLErrorNetworkConnectionLost,    // -1005
		NSURLErrorCannotFindHost,           // -1003
		NSURLErrorCannotConnectToHost       // -1004
	]
}
