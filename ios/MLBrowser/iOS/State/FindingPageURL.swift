//
//  FindingPageURL.swift
//  AI Archeology
//
//  Deciding which URL a finding actually stores, once the field became editable (AIA-0817).
//

import Foundation

/// Turns the save sheet's page field plus the captured URL into the value to persist.
///
/// Pulled out of the view and the repository into one pure place because the interesting rules are
/// all "what happens when these disagree", and neither of those is a comfortable place to test
/// that. By the time the repository has a `URL?` in hand, the difference between "the user cleared
/// it" and "the user typed something unusable" is already gone.
///
/// The stake is higher than it looks. `Finding.isValidPageURL` rejects any scheme but http(s), and
/// `FindingRepository.save` turns a validation failure into a thrown error that deletes the row
/// **and its screenshot** — so an unstorable URL reaching the entity does not produce a finding
/// with a missing page, it loses the finding entirely.
enum FindingPageURL {

	/// The URL to persist for a finding.
	///
	/// - `edited` is the raw text of the page field, exactly as typed.
	/// - `captured` is what the browser resolved at capture time.
	///
	/// Rules, in order:
	/// 1. an empty field means the user deliberately cleared it — store nothing;
	/// 2. a usable edit wins, because the user is correcting a URL the app got wrong, which is the
	///    whole reason the field is editable;
	/// 3. anything else falls back to the captured URL. Refusing to save, or storing the unusable
	///    text, would both punish a typo by losing the page the app had correctly recorded.
	static func resolve(edited: String, captured: URL?) -> URL? {
		let trimmed = edited.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.isEmpty.not else { return nil }
		if let edit = url(from: trimmed) { return edit }
		return storable(captured)
	}

	/// The captured URL, if it can be stored at all.
	///
	/// A capture is not always a web page: the UI-test harness loads `file://` fixtures, and a
	/// content-process crash can leave `about:blank`. Those must become "no page recorded" rather
	/// than reaching validation, where they would destroy the finding.
	static func storable(_ url: URL?) -> URL? {
		guard let url, Finding.isValidPageURL(url) else { return nil }
		return url
	}

	/// Parses typed text into a storable URL.
	///
	/// A scheme-less host gets `https://` rather than the address bar's `http://`: this value is
	/// stored provenance that may be opened much later by someone else, not a load being performed
	/// right now, so the secure default is the better guess.
	/// Whether the text starts with `scheme:` rather than merely containing a port.
	///
	/// `example.org:8080/map` has a colon and no scheme; `mailto:x@y.com` has a scheme. The
	/// difference is what follows the colon: a port is digits.
	private static func declaresAScheme(_ text: String) -> Bool {
		guard let colon = text.firstIndex(of: ":") else { return false }
		let after = text[text.index(after: colon)...]
		let port = after.prefix { $0.isNumber }
		// `host:8080/...` — digits then a delimiter or the end — is a port, not a scheme. All three
		// delimiters count: `host:8080?x=1` and `host:8080#frag` are as much ports as `host:8080/map`,
		// and testing only for `/` classified them as schemes, so `https://` was never prefixed and
		// the edit silently fell back to the captured URL (raised in review).
		if port.isEmpty.not, after.dropFirst(port.count).first.map({ "/?#".contains($0) }) ?? true { return false }
		return true
	}

	private static func url(from text: String) -> URL? {
		if let direct = URL(string: text), Finding.isValidPageURL(direct) { return direct }
		// A colon usually means the text already declares a scheme, and prefixing one we just
		// rejected would turn `mailto:someone@example.com` into `https://mailto:someone@…` — a URL
		// that validates and points nowhere. But a colon is also a PORT, so the test is for a
		// scheme specifically: everything before the colon being non-numeric after the first dot.
		guard text.contains("."), text.contains(" ").not, declaresAScheme(text).not,
		      let prefixed = URL(string: "https://\(text)"), Finding.isValidPageURL(prefixed)
		else { return nil }
		return prefixed
	}
}
