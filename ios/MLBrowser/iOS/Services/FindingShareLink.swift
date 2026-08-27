//
//  FindingShareLink.swift
//  AI Archeology
//
//  The shareable-finding link contract (AIA-0650): build one, parse one back.
//

import Foundation

/// Builds and parses the links that carry a finding out of the app and back into it (AIA-0650).
///
/// Deliberately free of UIKit, SwiftUI and Core Data so the contract can be round-tripped in a unit
/// test without a host app — the parser is the only thing standing between a stranger's URL and a
/// screen in this app, so it is the piece that most needs to be cheap to test exhaustively.
///
/// ## Why the payload lives in the fragment
/// Everything after `#` is **never transmitted to the server**. The same payload in a query string
/// would reach the hosting provider's request log, its cache key and the `Referer` of every outbound
/// click — a per-open upload of the finding's title, its author's name, its coordinates and the page
/// it was captured on. AGENTS §10 and this ticket's own acceptance criteria forbid exactly that, and
/// a static landing page has no use for server-side parameters anyway.
///
/// The cost is stated rather than hidden: a fragment is invisible to link-preview crawlers, so a
/// pasted link renders a generic card instead of a per-finding one. The shared *image* already
/// carries the finding visually, so this buys privacy with something we were not relying on.
///
/// ## What the link does not do
/// Associated Domains authenticates the **domain**, never the parameters. Every field here is
/// attacker-controllable by anyone willing to type a URL, so a parsed payload is *unverified content
/// from a stranger* and the UI that renders it must say so. ``page`` is the sharp edge — it is a
/// URL this app will offer to open — which is why it is restricted to `https`, refused outright if
/// it carries embedded credentials, and reduced to the widest form that fits its cap. Since
/// AIA-0657 that form can include the query and fragment, because a map viewer keeps the view
/// there; see ``sanitizedPage(_:detail:)`` for what is still removed and what is merely shown to
/// the sender.
enum FindingShareLink {

	// MARK: - Contract constants

	/// The host that serves the landing page and the `apple-app-site-association` file.
	static let webHost = "link.aiarcheology.com"

	/// The single path universal links use. **Pinned without a trailing slash**, and the
	/// `apple-app-site-association` file must list this exact string.
	///
	/// iOS matches the association against the URL *as tapped*, before any HTTP redirect runs — so
	/// if the host redirects `/f` to `/f/` (which directory-style static hosting does by default),
	/// a link emitted as `/f` while the association lists `/f/` simply never opens the app, with no
	/// error anywhere. The landing page is therefore served from `f.html`, not `f/index.html`.
	static let path = "/f"

	/// The already-registered custom scheme (`MLBrowser-Info.plist`, `CFBundleURLTypes`), accepted on
	/// input and **never emitted**. It exists so the flow is testable and demoable before the web host
	/// is live, since universal links cannot work until the association file is served.
	static let customScheme = "com.aiarcheology.ios"

	/// The custom scheme's equivalent of ``path``. `com.aiarcheology.ios://f` parses as **host `f`
	/// with an empty path** — not path `/f` — so the two grammars are matched separately rather than
	/// through one path comparison that silently rejects the scheme form.
	static let customHost = "f"

	/// Schema version. A link from a newer app is not guessed at: the landing page shows only the
	/// App Store link, and the app declines to render a payload it may misread.
	static let version = "1"

	/// Ceiling for the full link. Not a URL limit — a courtesy to the destinations that carry it as
	/// text, several of which wrap or truncate long strings.
	static let maximumLength = 900

	/// Ceiling for the QR variant, which is far tighter than the text one and for a physical reason.
	///
	/// A fragment payload forces QR **byte** mode (`#`, `&`, `=` and lowercase all fall outside
	/// alphanumeric mode). At 900 characters that is roughly a version-24 symbol — about 113 modules
	/// across — and at 88pt on a 3× canvas that is 264px ÷ 113 ≈ 2.3px per module. Below roughly 3px
	/// per module a code stops surviving being photographed off a screen, which is the only way a
	/// reposted card is ever scanned.
	///
	/// **400 characters at EC-M is a version-15 symbol: 77 modules, plus the generator's one-module
	/// quiet zone each side = 79.** ``FindingShareQRCode/image(for:pixelSize:)`` *floors* the scale
	/// factor, so the real margin is `floor(264 / 79) = 3`px per module — identical to the 250/64pt
	/// pairing it replaces (`floor(192 / 63) = 3`), which is why the budget could grow at all.
	///
	/// The superseded comment claimed 250 characters "lands near version 10 (57 modules)". It does
	/// not: v10 holds 213 bytes at EC-M, so 250 needed v11 (61 modules). Recorded because the same
	/// arithmetic is what justifies the new number.
	static let maximumCompactLength = 400

	/// The longest URL the parser will look at, and a *defensive* limit rather than a contract one.
	///
	/// Nothing this app emits comes close — ``maximumLength`` caps that at 900. This bounds what an
	/// arbitrary caller can make the parser do: the custom scheme is registered app-wide, so any app
	/// on the device can hand this one a URL of its choosing, and the work happens on the main actor.
	/// The slack over 900 tolerates a link someone hand-edited without inviting unbounded parsing.
	static let maximumAcceptedLength = 2048

	/// The most key/value pairs the parser will consider. A URL inside ``maximumAcceptedLength`` can
	/// still hold hundreds of two-character pairs; the contract defines nine.
	static let maximumAcceptedFields = 32

	private enum Key {
		static let version = "v"
		static let id = "i"
		static let title = "t"
		static let detectionClass = "c"
		static let confidence = "p"
		static let coordinate = "g"
		static let box = "b"
		static let page = "u"
		static let author = "a"
		static let date = "d"
	}

	/// Per-field caps on the *decoded* value, applied on the way in as well as on the way out. A
	/// hostile link can otherwise hand the UI a megabyte of text in a field the card renders.
	private enum Limit {
		static let title = 80
		static let compactTitle = 40
		static let detectionClass = 60
		static let author = 60
		/// The reduced page form — scheme, host and path only.
		static let page = 400
		/// The full form, which carries the query and fragment a map viewer keeps its view in.
		/// Larger because that is the whole point: a portal's view parameters are frequently longer
		/// than the path they hang off.
		static let fullPage = 600
	}

	// MARK: - Payload

	/// A geographic point that has already been validated as renderable.
	struct Coordinate: Hashable, Sendable {
		let latitude: Double
		let longitude: Double

		/// Fails rather than clamping: a coordinate outside the real range is a malformed link, and
		/// clamping would silently drop a pin somewhere the sender never was.
		init?(latitude: Double, longitude: Double) {
			guard latitude.isFinite, longitude.isFinite,
			      (-90...90).contains(latitude), (-180...180).contains(longitude)
			else { return nil }
			self.latitude = latitude
			self.longitude = longitude
		}
	}

	/// Where on the **captured view** the detection sat, as fractions of that view.
	///
	/// ## Which rectangle this is, said precisely
	/// The captured view is the on-screen snapshot taken at detection time — a WKWebView viewport
	/// capture, not the whole scrollable document, and **not** the finding's stored image, which is
	/// the crop the sender framed in the save sheet. Those three drift apart the moment anyone
	/// pinches the crop editor, and this one is the only one a recipient can act on: they have the
	/// page (`u`) and this rectangle, and no crop to reconcile anything against.
	///
	/// A finding that never recorded its capture-space box carries **no box at all** rather than
	/// its cropped one — see `Finding.captureBoxX…`. That is why the field is optional in practice
	/// even though the parser treats it as either-valid-or-absent (AIA-0761).
	///
	/// ## Top-left origin, deliberately not Vision's
	/// `Finding.normalizedBox` is a **Vision** rect: bottom-left origin, which is why every drawing
	/// site in the app goes through `CGRect.visionRect(in:)`. That convention stops here. This wire
	/// format has a second reader — the landing page — and a Y axis pointing the other way from every
	/// web coordinate system is a disagreement waiting to happen, with nothing in the link to say
	/// which way is up. The landing page does not render `b` *yet* (it ignores unknown fields by
	/// design); picking the convention now is what keeps that from becoming a decision made under
	/// pressure later. The same shape as the ``parseWireCoordinate(_:)``
	/// divergence recorded below: one spelling on the wire, converted at the boundary.
	///
	/// ## What it does *not* carry
	/// The captured view's aspect ratio does not travel, so a receiver can place the box and size it
	/// **relative to the page**, but cannot know its true proportions. Position and area survive as
	/// fractions, to the wire's four decimals — about a millimetre on a page-sized capture — while
	/// the drawn shape is indicative only. A fifth component would buy just the shape, at the price
	/// of another validation rule and another thing for two implementations to disagree about.
	struct Box: Hashable, Sendable {
		let x: Double
		let y: Double
		let width: Double
		let height: Double

		/// Fails rather than clamping, like ``Coordinate``: a box outside the unit square is a
		/// malformed link, and a silently shrunk one would point at the wrong part of the page.
		///
		/// A zero-area box is refused too. `Finding.normalizedBox` is `.zero` for any row saved
		/// before detection boxes were stored, and "the detection is at the origin and infinitely
		/// small" is not a thing to draw on a stranger's screen.
		init?(x: Double, y: Double, width: Double, height: Double) {
			guard [x, y, width, height].allSatisfy(\.isFinite),
			      (0...1).contains(x), (0...1).contains(y),
			      width > 0, height > 0,
			      // A hair of slack for binary representation only: `0.1 + 0.2` is 0.30000000000000004,
			      // so a box whose edges are exact in decimal can sum to a hair over 1 in binary.
			      // Wire rounding is handled by quantizing before emission, never by widening this.
			      x + width <= 1 + 1e-9,
			      y + height <= 1 + 1e-9
			else { return nil }
			self.x = x
			self.y = y
			self.width = width
			self.height = height
		}

		/// The fraction of the captured view the detection covers. Aspect-invariant, so it is one of
		/// the two things a receiver may state as fact.
		var areaFraction: Double { width * height }
	}

	/// How much of the captured page's address a link may carry.
	///
	/// The two forms exist because one answer does not fit both cases this app serves. On an
	/// ordinary page the path identifies the content and the query is where session tokens live. On
	/// a geoportal — this app's whole subject — the query *is* the view, and a link without it lands
	/// the recipient on a homepage holding none of what was shared.
	enum PageDetail: Hashable, Sendable, CaseIterable {
		/// Scheme and host. Not offered to the sender — it is the **floor** the reduction ladder
		/// stops at, and it is not nothing: a host names the service a finding came from, which is
		/// the degraded-but-useful case the ticket forbids losing on the way to something better.
		case hostOnly
		/// Scheme, host and path. The safe default, and what every link emitted before AIA-0657
		/// carried.
		case siteOnly
		/// Everything that identifies the view, minus anything shaped like a credential. Chosen by
		/// the sender, who is shown the exact address first.
		case full

		/// The forms to try, widest first, when this one will not fit.
		///
		/// The ladder exists because an address is the one field with more than one truthful form:
		/// every rung still names the same place, just less precisely. That is what lets the
		/// contract promise the address is never *dropped* — only reduced.
		var reductions: [PageDetail] {
			switch self {
			case .full: return [.full, .siteOnly, .hostOnly]
			case .siteOnly: return [.siteOnly, .hostOnly]
			case .hostOnly: return [.hostOnly]
			}
		}
	}

	/// The finding, reduced to what fits in a link. Every field except ``title`` is optional because
	/// every field except the title is optional on a `Finding` too.
	struct Payload: Hashable, Sendable {
		/// The originating finding's identifier, used for **one** purpose: looking it up in the
		/// recipient's own store. A match means the recipient already owns this finding — typically
		/// the sender testing their own link — and the app opens the real finding rather than showing
		/// its owner a stranger's-eye read-only card of their own work.
		///
		/// It identifies nothing outside this app: a random UUID reveals less than the title and
		/// author name already in the same link.
		let id: UUID?
		let title: String
		let detectionClass: String?
		/// Whole percent, `0...100`. Stored as the integer that travels, not the `0...1` Double the
		/// model produces, so the link never carries more precision than it renders.
		let confidencePercent: Int?
		let coordinate: Coordinate?
		/// Where on the page the detection sat. For a detection on an ordinary page this is the
		/// locator — the page plus where on it — in a way a coordinate never is, since `Finding.gps_`
		/// is hand-typed and usually empty.
		let box: Box?
		/// The page the finding was captured on — `https` only, at the detail the sender chose.
		/// See ``sanitizedPage(_:detail:)``.
		let page: URL?
		let author: String?
		/// Day precision. A finding's capture *time* is a movement record; the date alone is context.
		let date: DateComponents?

		init(
			id: UUID? = nil,
			title: String,
			detectionClass: String? = nil,
			confidencePercent: Int? = nil,
			coordinate: Coordinate? = nil,
			box: Box? = nil,
			page: URL? = nil,
			author: String? = nil,
			date: DateComponents? = nil
		) {
			self.id = id
			self.title = title
			self.detectionClass = detectionClass
			self.confidencePercent = confidencePercent
			self.coordinate = coordinate
			self.box = box
			self.page = page
			self.author = author
			self.date = date
		}
	}

	/// Which of the two links is being built.
	enum Variant {
		/// The link shared as text — carries every field that fits.
		case full
		/// The link encoded into the QR printed on the card. Shortens the title to stay scannable;
		/// both variants still resolve to the same finding.
		///
		/// It **no longer drops ``Payload/page``**. Removing it unconditionally meant the artifact
		/// most likely to be reposted — a code printed into an image, which survives a screenshot of
		/// a screenshot — was the one carrying no way back to the page (AIA-0657).
		case compact

		var lengthLimit: Int {
			switch self {
			case .full: return maximumLength
			case .compact: return maximumCompactLength
			}
		}

		var titleLimit: Int {
			switch self {
			case .full: return Limit.title
			case .compact: return Limit.compactTitle
			}
		}
	}

	// MARK: - Build

	/// Builds the shareable link, dropping optional fields from the least important upwards until it
	/// fits ``Variant/lengthLimit``.
	///
	/// Returns `nil` only when even a title-and-version link cannot fit, which a non-empty title
	/// cannot cause — but it is expressed as a failure rather than an over-long link so a caller can
	/// never ship something unscannable by accident.
	static func url(for payload: Payload, variant: Variant = .full, pageDetail: PageDetail = .siteOnly) -> URL? {
		// The page is the one field with several *forms*, so it is never dropped — it is reduced.
		// Everything else that will not fit is shed first, then the title is shortened, and only
		// then does the address step down a rung: full → site → host. Dropping it outright is the
		// outcome this contract refuses to produce, because the card prints only
		// `link.aiarcheology.com` and a code with no page is a picture of nothing.
		for detail in pageDetail.reductions {
			if let fitted = fitted(payload, variant: variant, pageDetail: detail) { return fitted }
		}
		return nil
	}

	/// One pass of the drop ladder at a fixed page detail. `nil` means "not at this detail".
	private static func fitted(_ payload: Payload, variant: Variant, pageDetail: PageDetail) -> URL? {
		// Least important first. `g` leads because a hand-typed coordinate is the field a finding is
		// least likely to have at all; `i` trails because it is mechanism rather than content — its
		// only job is recognising a link to a finding the recipient already owns. The product owner
		// ranked the rest: title, address and author are the must-haves, so `a` is the last piece of
		// *content* to go and `t` and `u` never go (AIA-0657).
		let droppable: [String] = [
			Key.coordinate, Key.date, Key.detectionClass, Key.confidence, Key.box, Key.author, Key.id
		]
		var dropped: Set<String> = []

		while true {
			guard let candidate = assemble(payload, variant: variant, pageDetail: pageDetail, dropping: dropped) else { return nil }
			if candidate.absoluteString.count <= variant.lengthLimit { return candidate }
			guard let next = droppable.first(where: { dropped.contains($0).not }) else {
				// Everything droppable is gone and it still does not fit: the title and the address
				// together are too long. Shorten the title rather than return an over-long link.
				return assembleTruncated(payload, variant: variant, pageDetail: pageDetail, dropping: dropped)
			}
			// `c` and `p` are two keys for one idea — a class with no confidence beside it reads as
			// more certain than it is, so they leave together.
			dropped.insert(next)
			if next == Key.detectionClass { dropped.insert(Key.confidence) }
		}
	}

	private static func assemble(
		_ payload: Payload,
		variant: Variant,
		pageDetail: PageDetail,
		dropping dropped: Set<String>,
		titleOverride: String? = nil
	) -> URL? {
		// The title is the one field with no optional form: a card with nothing written on it is the
		// blank screen this ticket's fourth acceptance criterion exists to prevent. Refusing here
		// rather than emitting a version-only link also keeps the builder and the parser honest —
		// `payload(from:)` rejects a titleless link, so emitting one would mean shipping a link this
		// app cannot itself read.
		guard sanitizedText(payload.title, limit: variant.titleLimit) != nil else { return nil }

		var pairs: [(String, String)] = [(Key.version, version)]

		func add(_ key: String, _ value: String?) {
			guard dropped.contains(key).not, let value, value.isEmpty.not else { return }
			pairs.append((key, value))
		}

		add(Key.id, payload.id?.uuidString)
		add(Key.title, sanitizedText(titleOverride ?? payload.title, limit: variant.titleLimit))
		add(Key.detectionClass, sanitizedText(payload.detectionClass, limit: Limit.detectionClass))
		// Range-checked on the way out as well as the way in. `Payload` is a plain struct that
		// validates nothing, so a directly-constructed one could emit `p=101` — which this app's own
		// parser then drops, producing a link it cannot fully read back. Same asymmetry that let the
		// page's query string escape; closed the same way, at the boundary rather than by convention.
		add(Key.confidence, payload.confidencePercent.flatMap { (0...100).contains($0) ? String($0) : nil })
		add(Key.coordinate, payload.coordinate.map(formatted))
		add(Key.box, payload.box.flatMap(formattedBox))
		// Reduced again on the way out, even though `FindingShareSubject.linkPayload` already reduced
		// it. Not redundant: `Payload` is a plain struct that validates nothing, so "the page is
		// safe" was previously a property of one *caller* remembering to call `sanitizedPage`, and
		// this contract is the wrong place to hold a security property by convention. Reducing here
		// makes it true of every link this type can emit, whoever built the payload. The original bug
		// was invisible in tests because a round-trip check parses on the way back in — and the
		// parser sanitizes — so the emitted link carried the query string while the test passed.
		//
		// `pageDetail` defaults to `.siteOnly` at every entry point, so a caller that forgets to
		// pass one emits the narrower link, never the wider. The sender's choice has to be spoken
		// aloud to take effect.
		add(Key.page, payload.page.flatMap { sanitizedPage($0.absoluteString, detail: pageDetail) }?.absoluteString)
		add(Key.author, sanitizedText(payload.author, limit: Limit.author))
		add(Key.date, payload.date.flatMap(formattedDate))

		let fragment = pairs
			.map { "\($0.0)=\(percentEncoded($0.1))" }
			.joined(separator: "&")

		var components = URLComponents()
		components.scheme = "https"
		components.host = webHost
		components.path = path
		components.percentEncodedFragment = fragment
		return components.url
	}

	/// Last resort when even a stripped link overruns: keep everything that survived, and shorten
	/// the title to whatever room is left.
	///
	/// The budget is **measured, not assumed**. The superseded version computed it as
	/// "version + title" alone, which was true only while this fallback threw every other field
	/// away — it now keeps the address, so a fixed overhead would have produced exactly the
	/// over-long link the whole ladder exists to prevent. Assembling the same payload once with the
	/// title dropped gives the real cost of everything else.
	private static func assembleTruncated(
		_ payload: Payload,
		variant: Variant,
		pageDetail: PageDetail,
		dropping dropped: Set<String>
	) -> URL? {
		guard let withoutTitle = assemble(
			payload,
			variant: variant,
			pageDetail: pageDetail,
			dropping: dropped.union([Key.title])
		) else { return nil }

		let separator = "&\(Key.title)=".count
		let budget = variant.lengthLimit - withoutTitle.absoluteString.count - separator
		guard budget > 0, let cleaned = sanitizedText(payload.title, limit: variant.titleLimit) else { return nil }
		let fitted = fittingEncodedLength(cleaned, budget: budget)
		// Nothing of the title survives, so there is no honest link to emit. The caller prints the
		// readable address alone rather than a code that says nothing.
		guard fitted.isEmpty.not else { return nil }

		let candidate = assemble(
			payload,
			variant: variant,
			pageDetail: pageDetail,
			dropping: dropped,
			titleOverride: fitted
		)
		// The measurement above is arithmetic on an assembled string, but the assembled string is
		// what ships — so it is checked rather than trusted.
		guard let candidate, candidate.absoluteString.count <= variant.lengthLimit else { return nil }
		return candidate
	}

	/// Trims `text` until its **percent-encoded** form fits `budget`.
	///
	/// Budgeting by character count does not work here, and fails worst on exactly the titles that
	/// need trimming: one `Ω` becomes six characters once encoded and a single emoji can become
	/// twelve, so a character-count budget can overshoot the real limit several times over. Measured
	/// per grapheme so a multi-scalar cluster is never cut in half.
	private static func fittingEncodedLength(_ text: String, budget: Int) -> String {
		var fitted = ""
		for character in text {
			let candidate = fitted + String(character)
			guard percentEncoded(candidate).count <= budget else { break }
			fitted = candidate
		}
		return fitted
	}

	// MARK: - Parse

	/// Parses a link produced by ``url(for:variant:)``, or returns `nil`.
	///
	/// Tolerant of *absent* data and hostile about *malformed* data: a missing optional field is
	/// simply absent from the result, while a value that cannot be trusted (an unparseable
	/// coordinate, a non-`https` page, a confidence outside `0...100`) is dropped rather than
	/// carried through in a degraded form. A link with no usable title is rejected outright, because
	/// a card with nothing on it is the blank screen this ticket's fourth acceptance criterion names.
	static func payload(from url: URL) -> Payload? {
		guard matches(url) else { return nil }
		// Bounded before any parsing work happens, because this runs on the main actor and the input
		// is not ours. `matches` only proves the scheme and path are ours — the custom scheme is
		// registered app-wide, so *any* app on the device can hand us
		// `com.aiarcheology.ios://f#<megabytes>`. Percent-decoding, splitting and normalising that
		// first and rejecting it afterwards is a way to stall the UI process on demand. Our own links
		// cap at `maximumLength`; the slack above it tolerates a hand-edited link without inviting
		// unbounded work.
		guard url.absoluteString.count <= maximumAcceptedLength else {
			LoggingPolicy.warning("Shared finding: refusing an oversized link", logger: .state)
			return nil
		}
		guard let items = fragmentItems(of: url) else { return nil }
		// Same reasoning one level down: a bounded-length fragment can still carry thousands of
		// key/value pairs, and every one of them is allocated before the duplicate check below.
		guard items.count <= maximumAcceptedFields else { return nil }

		// Duplicate keys are rejected rather than resolved. There is no correct answer to which of
		// two titles was meant, and "first wins" versus "last wins" is exactly the kind of quiet
		// disagreement that lets the app and the landing page render different things from one link.
		let keys = items.map(\.name)
		guard Set(keys).count == keys.count else { return nil }

		var fields: [String: String] = [:]
		for item in items {
			guard let value = item.value, value.isEmpty.not else { continue }
			fields[item.name] = value
		}

		guard fields[Key.version] == version else { return nil }
		guard let title = sanitizedText(fields[Key.title], limit: Limit.title) else { return nil }

		return Payload(
			id: fields[Key.id].flatMap(UUID.init(uuidString:)),
			title: title,
			detectionClass: sanitizedText(fields[Key.detectionClass], limit: Limit.detectionClass),
			confidencePercent: fields[Key.confidence].flatMap(parseConfidence),
			coordinate: fields[Key.coordinate].flatMap(parseWireCoordinate),
			box: fields[Key.box].flatMap(parseBox),
			page: fields[Key.page].flatMap(acceptedPage),
			author: sanitizedText(fields[Key.author], limit: Limit.author),
			date: fields[Key.date].flatMap(parseDate)
		)
	}

	/// Whether `url` is one this app should even look at. Everything else — including every Clerk
	/// OAuth callback on the same custom scheme — is ignored, which is what keeps a scene-level
	/// `onOpenURL` from stealing URLs that belong to someone else.
	static func matches(_ url: URL) -> Bool {
		guard let scheme = url.scheme?.lowercased() else { return false }
		switch scheme {
		case "https":
			return url.host?.lowercased() == webHost && normalizedPath(url.path) == path
		case customScheme:
			// The custom form is `com.aiarcheology.ios://f#…`: host `f`, empty path.
			return url.host?.lowercased() == customHost && normalizedPath(url.path).isEmpty
		default:
			return false
		}
	}

	/// Collapses a trailing slash so `/f` and `/f/` compare equal *inside the app*. The association
	/// file cannot do this — iOS matches the tapped URL literally — which is why ``path`` is pinned
	/// and the host is configured not to redirect between the two forms.
	private static func normalizedPath(_ raw: String) -> String {
		guard raw.count > 1, raw.hasSuffix("/") else { return raw }
		return String(raw.dropLast())
	}

	/// Reads the fragment **without letting Foundation decode it first**.
	///
	/// `URLComponents.fragment` returns a percent-*decoded* string, so splitting that on `&` and `=`
	/// mis-splits any value whose own text contains one — a title of "Rome & Byzantium" becomes two
	/// fields. Taking `percentEncodedFragment` and handing it back to `URLComponents` as a query
	/// makes Apple's per-item decoder do the splitting, which is the same code path `queryItems`
	/// uses and is correct by construction.
	private static func fragmentItems(of url: URL) -> [URLQueryItem]? {
		guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment,
		      raw.isEmpty.not
		else { return nil }
		return URLComponents(string: "?" + raw)?.queryItems
	}

	// MARK: - Field encoding & validation

	/// The characters safe to leave unescaped in a fragment value.
	///
	/// `CharacterSet.urlQueryAllowed` is **not** a safe default here: it permits `&`, `=`, `+`, `?`
	/// and `#`, so encoding a title with it emits a string that breaks the very parser on the other
	/// end of this file. Each is removed for a concrete reason — `&` and `=` are the separators, `#`
	/// would start a second fragment, `?` confuses the query re-parse in ``fragmentItems(of:)``, and
	/// `+` is read as a space by enough third-party parsers to be worth escaping for the landing
	/// page's benefit.
	private static let valueAllowed: CharacterSet = CharacterSet.urlQueryAllowed
		.subtracting(CharacterSet(charactersIn: "&=+?#"))

	private static func percentEncoded(_ value: String) -> String {
		value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? ""
	}

	/// Trims, strips characters that have no business in a label, and caps the length.
	///
	/// Control characters and the Unicode bidirectional overrides are removed rather than escaped:
	/// they render as nothing while reordering everything after them, which is how a title can be
	/// made to display something other than what it contains. Returns `nil` for anything that is
	/// empty once cleaned, so callers can treat "absent" and "blank" identically.
	private static func sanitizedText(_ raw: String?, limit: Int) -> String? {
		guard let raw else { return nil }
		let cleaned = raw.unicodeScalars
			.filter { scalar in
				CharacterSet.controlCharacters.contains(scalar).not
					&& bidiControls.contains(scalar).not
			}
			.reduce(into: "") { $0.unicodeScalars.append($1) }
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard cleaned.isEmpty.not else { return nil }
		return cleaned.count <= limit ? cleaned : String(cleaned.prefix(limit))
	}

	/// LRE, RLE, PDF, LRO, RLO, LRI, RLI, FSI, PDI — the overrides that let text render in an order
	/// other than the one it is stored in.
	private static let bidiControls = CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")

	/// Parses the **wire** form of `g`: exactly two plain decimals separated by one comma.
	///
	/// Deliberately *not* ``CoordinateText/parse(_:)``. That one reads the finding's hand-typed GPS
	/// field, where a person may reasonably write `48.8N`, `48.8°` or `+48.8` — leniency is the point.
	/// This reads what travels in a link, which the builder always emits as `%.5f,%.5f`, and which a
	/// second implementation (the landing page) parses independently with a strict decimal regex.
	///
	/// Sharing the lenient parser between the two made them disagree: `g=+48.8,+19.53` produced a map
	/// in the app and no location at all on the web page. A wire format is a contract between two
	/// programs and should accept exactly one spelling; a text field is a conversation with a person
	/// and should accept several.
	private static func parseWireCoordinate(_ raw: String) -> Coordinate? {
		let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
		guard parts.count == 2,
		      let latitude = strictDecimal(String(parts[0])),
		      let longitude = strictDecimal(String(parts[1]))
		else { return nil }
		return Coordinate(latitude: latitude, longitude: longitude)
	}

	/// `-?\d+(\.\d+)?` and nothing else: no leading `+`, no exponent, no hex, no whitespace, no
	/// non-ASCII digits. Mirrors the landing page's regex exactly so both ends accept the same set.
	private static func strictDecimal(_ raw: String) -> Double? {
		var body = raw
		if body.hasPrefix("-") { body.removeFirst() }
		let halves = body.split(separator: ".", omittingEmptySubsequences: false)
		guard (1...2).contains(halves.count),
		      halves.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
		else { return nil }
		guard let value = Double(raw), value.isFinite else { return nil }
		return value
	}

	private static func parseConfidence(_ raw: String) -> Int? {
		// Digits only. `Int("+5")` succeeds and `Int(" 5")` does not, which is a distinction nobody
		// intended and one the landing page's regex does not share — it rejects `+5`. The wire format
		// is plain digits, so both ends now say so explicitly rather than inheriting whatever their
		// standard library happens to allow.
		guard raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber), raw.count <= 3 else { return nil }
		guard let value = Int(raw), (0...100).contains(value) else { return nil }
		return value
	}

	/// Reduces a captured page URL to what the sender chose to send — the **emission** side.
	///
	/// **`https` only.** `http` is refused outright rather than upgraded, and a URL carrying
	/// embedded credentials is refused entirely rather than stripped, because a link that needed a
	/// password is not one to hand on.
	///
	/// ## What changed in AIA-0657, and what it costs
	/// This used to drop the query and fragment unconditionally, and that reduction was described as
	/// *the* security property of this type. It is no longer, and the comment saying so has been
	/// removed rather than left half-true. For a geoportal — the thing this app exists to look at —
	/// the view lives in the query or the fragment, so stripping it handed the recipient a homepage
	/// and called it a shared finding.
	///
	/// The property that replaces it is **visibility**: the composer shows the sender the exact
	/// address this function returns, and reducing it to ``PageDetail/siteOnly`` is one tap. What is
	/// still removed automatically is a small set of parameter names that are credentials and never
	/// view state — see ``strippingCredentials(from:)``. What is *not* detectable, and is stated
	/// rather than papered over: a credential in a path segment, inside a nested `redirect=`
	/// parameter, or under a name this list has never heard of.
	///
	/// The length cap applies to the **result**, not the input. Capping the raw string first — which
	/// is what this did — meant a 600-character portal URL produced no page at all, so the very
	/// links this ticket exists to fix were the ones silently losing their address entirely.
	///
	/// **Internal, not private, and that is load-bearing.** `FindingShareSubject.linkPayload` is the
	/// one place a raw browsed URL enters this contract, and it calls this.
	static func sanitizedPage(_ raw: String, detail: PageDetail = .siteOnly) -> URL? {
		guard raw.count <= maximumAcceptedLength,
		      let components = URLComponents(string: raw),
		      components.scheme?.lowercased() == "https",
		      let host = components.host, host.isEmpty.not,
		      // Refused entirely rather than stripped: a link that needed a password is not one to
		      // hand on. (Refusal, so there is nothing left to clear afterwards.)
		      components.user == nil, components.password == nil
		else { return nil }

		// **Reduces rather than refuses when only the length fails.** Returning `nil` here was a
		// silent hole: the builder omits a `nil` page, the shortened link then fits comfortably, and
		// the ladder in `url(for:variant:pageDetail:)` never fires — so a portal address longer than
		// `.full`'s cap produced a link carrying *no address at all*, which is the one outcome this
		// contract says it refuses to produce. A too-long address is not an untrustworthy one; it is
		// an address we can only carry less of.
		for candidate in detail.reductions {
			guard let url = reduced(components, to: candidate),
			      url.absoluteString.count <= limit(for: candidate)
			else { continue }
			return url
		}
		return nil
	}

	/// One rung of the ladder: the same address, told with less precision.
	private static func reduced(_ components: URLComponents, to detail: PageDetail) -> URL? {
		var components = components
		switch detail {
		case .hostOnly:
			components.path = ""
			components.query = nil
			components.fragment = nil
		case .siteOnly:
			components.query = nil
			components.fragment = nil
		case .full:
			components.percentEncodedQuery = strippingCredentials(
				from: components.percentEncodedQuery, requiringPairs: false
			)
			// The fragment goes through the same sieve *only* when it is written as key/value pairs,
			// which is where an OAuth implicit-flow `#access_token=…` would sit. OpenStreetMap writes
			// `#map=15/48.8/19.53`, which parses as one pair named `map` and survives untouched; a
			// fragment that is not pairs at all (`#section/3/detail`) is left exactly as it was
			// rather than re-encoded into something we do not understand.
			components.percentEncodedFragment = strippingCredentials(
				from: components.percentEncodedFragment, requiringPairs: true
			)
		}
		return components.url
	}

	/// Accepts a page URL that arrived in a link — the **parse** side.
	///
	/// Deliberately *not* ``sanitizedPage(_:detail:)``, and the difference is the denylist. Stripping
	/// parameters on the way in would protect nobody: the sender's credentials are the ones worth
	/// removing, they were removed on the way out, and a query that reached this device belongs to
	/// whoever wrote the link. Editing a stranger's URL before offering it to the user would only
	/// mean the address we show is not the address we open.
	static func acceptedPage(_ raw: String) -> URL? {
		guard raw.count <= maximumAcceptedLength,
		      let components = URLComponents(string: raw),
		      components.scheme?.lowercased() == "https",
		      let host = components.host, host.isEmpty.not,
		      components.user == nil, components.password == nil,
		      let url = components.url, url.absoluteString.count <= Limit.fullPage
		else { return nil }
		return url
	}

	private static func limit(for detail: PageDetail) -> Int {
		switch detail {
		case .hostOnly, .siteOnly: return Limit.page
		case .full: return Limit.fullPage
		}
	}

	/// Removes the key/value pairs whose **name** is a credential rather than a view.
	///
	/// Names are normalized (lowercased, `-` and `_` removed) before matching, so `access_token`,
	/// `accessToken`, `X-Api-Key` and `X-Amz-Signature` all reduce to something the lists below
	/// recognise. Two lists rather than one: an exact set for words that are ordinary English when
	/// they appear inside a longer name (`key` must not eat `keyword`, `sid` must not eat `wmsid`),
	/// and a substring set for words that are never anything but a credential wherever they appear.
	///
	/// Deliberately **no value-shape rule.** A long base64 value is a JSON Web Token about as often
	/// as it is a portal's encoded view state — `?state=eyJ…` is both, depending on the site — so a
	/// rule keyed on shape would silently delete the view this ticket exists to preserve, in exactly
	/// the case nobody can check. Names we are certain about are removed; the rest is shown to the
	/// sender, who can reduce the whole address with one tap.
	/// - Parameter requiringPairs: when `true`, a component that is not written entirely as `k=v`
	///   pairs is returned untouched. That is right for a **fragment**, which is free-form —
	///   `#section/3/detail` means nothing to this sieve and re-encoding it would corrupt a link
	///   that was fine. It is wrong for a **query**, where a valueless item is ordinary
	///   (`?debug&access_token=abc`) and bailing out would let the token beside it travel: one
	///   bare flag would switch the whole strip off.
	private static func strippingCredentials(from encoded: String?, requiringPairs: Bool) -> String? {
		// Read and rewrite in **percent-encoded** form. Going through `queryItems` would decode every
		// surviving value and re-encode it on the way back, so `%2F` could return as `/` — and the
		// address the composer shows the sender has to be the address that travels.
		guard let encoded, encoded.isEmpty.not,
		      let items = URLComponents(string: "?" + encoded)?.percentEncodedQueryItems,
		      items.isEmpty.not
		else { return encoded }

		if requiringPairs, items.contains(where: { $0.value == nil }) { return encoded }

		let kept = items.filter { isCredentialName($0.name).not }
		guard kept.count != items.count else { return encoded }
		guard kept.isEmpty.not else { return nil }

		var rebuilt = URLComponents()
		rebuilt.percentEncodedQueryItems = kept
		return rebuilt.percentEncodedQuery
	}

	private static func isCredentialName(_ raw: String) -> Bool {
		// **Decoded first.** The items arrive percent-encoded (deliberately — see the caller), and a
		// name is allowed to be encoded too: `access%5Ftoken` is `access_token`, and matching the
		// raw form would let a token through by spelling its underscore in hex.
		let decoded = raw.removingPercentEncoding ?? raw
		let name = decoded.lowercased().filter { $0 != "-" && $0 != "_" }
		if credentialNames.contains(name) { return true }
		return credentialSubstrings.contains { name.contains($0) }
	}

	/// Whole names only — each is a plausible word inside an innocent parameter.
	///
	/// `code` is deliberately **absent**. It names an OAuth authorization code, but on the portals
	/// this app is pointed at it far more often names a region, a layer or a map sheet — and an
	/// OAuth code is single-use and already spent by the time anyone is browsing a map with it. The
	/// trade favours the view reproducing.
	private static let credentialNames: Set<String> = [
		"auth", "authorization", "key", "pwd", "passwd", "sid", "session", "sig", "ticket"
	]

	/// Matched anywhere in the name: none of these appears in a parameter that describes a view.
	///
	/// `accesskey` and `sessionkey` are here for the spellings the exact list cannot reach —
	/// `AWSAccessKeyId` and `session_key` normalize to names that contain them but equal neither.
	///
	/// The known cost of substring matching, accepted rather than papered over: a legitimate
	/// `pageToken` pagination parameter is stripped too. Losing a page cursor degrades a view; a
	/// leaked bearer token is not recoverable, and the sender still sees the result either way.
	private static let credentialSubstrings: [String] = [
		"token", "secret", "password", "apikey", "accesskey", "sessionkey", "signature",
		"credential", "jwt", "sessionid"
	]

	/// Parses the wire form of `b`: exactly four plain decimals, `x,y,width,height`, top-left origin.
	///
	/// Shares ``strictDecimal(_:)`` with the coordinate parser for the same reason that one exists —
	/// the landing page reads this with a decimal regex, and a wire format two programs must agree
	/// on should accept exactly one spelling.
	private static func parseBox(_ raw: String) -> Box? {
		let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
		guard parts.count == 4 else { return nil }
		let values = parts.compactMap { strictDecimal(String($0)) }
		guard values.count == 4 else { return nil }
		return Box(x: values[0], y: values[1], width: values[2], height: values[3])
	}

	/// Formats a box, and emits it **only if this type would accept it back**.
	///
	/// Four decimals is about a millimetre on a page-sized capture, and quantizing to that grid can
	/// push an edge-touching box past the unit square: `x = 0.49995` and `width = 0.50005` sum to
	/// exactly 1 and are perfectly valid, but each rounds *up*, and `0.5000 + 0.5001` is 1.0001,
	/// which ``parseBox(_:)`` refuses. The extent is therefore quantized *toward the interior* — the
	/// box moves by at most a ten-thousandth, which is invisible — and the result is then
	/// round-tripped through the parser, so the builder can never emit a field its own parser
	/// rejects. Same idiom, and same reason, as ``formattedDate(_:)``.
	private static func formattedBox(_ box: Box) -> String? {
		let grid = 10_000.0
		// The **origin rounds down** and the extent rounds to nearest with a floor of one grid step.
		// Rounding the origin to nearest could carry it to 1.0 for a box hard against the far edge
		// (`x = 0.99995`), which leaves no room for any width at all and silently drops a box that
		// was perfectly valid — a detection in the last thousandth of a page is a small detection,
		// not an absent one. Rounding down leaves at least one step, and the extent's own floor
		// makes sure it is used.
		let x = (box.x * grid).rounded(.down) / grid
		let y = (box.y * grid).rounded(.down) / grid
		let width = min(max((box.width * grid).rounded(), 1) / grid, 1 - x)
		let height = min(max((box.height * grid).rounded(), 1) / grid, 1 - y)
		guard width > 0, height > 0 else { return nil }
		let text = String(format: "%.4f,%.4f,%.4f,%.4f", x, y, width, height)
		return parseBox(text) == nil ? nil : text
	}

	private static func formatted(_ coordinate: Coordinate) -> String {
		// Five decimals is ~1m — finer than a hand-typed coordinate ever justifies, and it keeps the
		// QR variant short.
		String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
	}

	/// Formats a day, and emits it **only if this type would accept it back**.
	///
	/// The round trip through ``parseDate(_:)`` is the validation: a `DateComponents` of the 30th of
	/// February formats perfectly happily, and without this the builder would emit `d=2026-02-30` —
	/// which our own parser drops, and which the landing page (a separate implementation) renders as
	/// a real date. Emitting only what we would parse keeps the two ends from disagreeing.
	private static func formattedDate(_ components: DateComponents) -> String? {
		guard let year = components.year, let month = components.month, let day = components.day else { return nil }
		let text = String(format: "%04d-%02d-%02d", year, month, day)
		return parseDate(text) == nil ? nil : text
	}

	/// Parses `yyyy-MM-dd` and rejects dates that do not exist.
	///
	/// Built by hand rather than with a formatter so the result is independent of the device's
	/// calendar, locale and time zone — a link written in one region must read identically in
	/// another. The round-trip through `Calendar` is what rejects the 30th of February, which a
	/// range check on each component alone would happily accept.
	private static func parseDate(_ raw: String) -> DateComponents? {
		let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
		guard parts.count == 3,
		      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
		      parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
		      (1...9999).contains(year)
		else { return nil }

		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
		let candidate = DateComponents(year: year, month: month, day: day)
		guard let date = calendar.date(from: candidate) else { return nil }

		let realized = calendar.dateComponents([.year, .month, .day], from: date)
		guard realized.year == year, realized.month == month, realized.day == day else { return nil }
		return candidate
	}
}

// MARK: - Free-text coordinates

/// Turns the finding's hand-typed `gps_` field into a point, when it can.
///
/// The field is a plain `TextField` with no validation anywhere in the app, so its contents are
/// whatever the user typed — a decimal pair, a pair with hemisphere letters, degree symbols, prose,
/// or nothing. Parsing is therefore best-effort by design: a value it cannot read means the link
/// carries no coordinate and the recipient sees no map, which is the common case rather than the
/// exceptional one.
enum CoordinateText {

	/// Accepts `48.8, 19.53`, `48.8 19.53`, `48.8N, 19.53E`, `N48.8 E19.53` and the degree-suffixed
	/// forms of each. Anything else yields `nil`.
	static func parse(_ raw: String) -> FindingShareLink.Coordinate? {
		let normalized = raw
			.replacingOccurrences(of: "°", with: " ")
			.replacingOccurrences(of: ";", with: ",")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		guard normalized.isEmpty.not else { return nil }

		let tokens = normalized
			.split(whereSeparator: { $0 == "," || $0.isWhitespace })
			.map(String.init)
		guard tokens.count == 2 else { return nil }

		guard let first = component(tokens[0], positive: "N", negative: "S"),
		      let second = component(tokens[1], positive: "E", negative: "W")
		else { return nil }

		return FindingShareLink.Coordinate(latitude: first, longitude: second)
	}

	/// Reads one signed magnitude, with an optional hemisphere letter on either side.
	///
	/// A hemisphere letter and an explicit sign together (`-48.8N`) is refused rather than resolved:
	/// the two disagree about which side of the equator the user meant, and guessing puts a pin in
	/// the wrong hemisphere with no indication anything was wrong.
	private static func component(_ token: String, positive: Character, negative: Character) -> Double? {
		var body = token.uppercased()
		var hemisphere: Character?

		if let last = body.last, last == positive || last == negative {
			hemisphere = last
			body.removeLast()
		} else if let first = body.first, first == positive || first == negative {
			hemisphere = first
			body.removeFirst()
		}

		body = body.trimmingCharacters(in: .whitespaces)
		guard body.isEmpty.not else { return nil }
		// `Double("1e5")`, `Double("inf")` and `Double("nan")` all succeed; none is a coordinate.
		guard body.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }) else { return nil }
		guard let magnitude = Double(body), magnitude.isFinite else { return nil }

		guard let hemisphere else { return magnitude }
		guard magnitude >= 0 else { return nil }
		return hemisphere == positive ? magnitude : -magnitude
	}
}
