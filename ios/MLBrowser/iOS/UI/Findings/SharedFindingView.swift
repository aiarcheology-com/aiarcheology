//
//  SharedFindingView.swift
//  AI Archeology
//
//  The read-only screen a recipient sees when they open a shared finding link (AIA-0650).
//

import SwiftUI
import MapKit

// MARK: - Which screen a pending link resolves to

/// The two screens a pending shared link can produce.
///
/// The distinction is not cosmetic. A link is *usually* someone else's finding, which is why the
/// unverified card exists at all — but the commonest link anyone ever opens is their own, because
/// the first thing a sender does is tap the link they just shared. Showing that person a
/// stranger's-eye "this has not been verified" card of their own work would be nonsense, so the id
/// in the link is matched against the local store first.
enum SharedFindingPresentation: Equatable {
	/// Content that arrived in a URL from someone else. Everything rendered is attacker-controllable
	/// and the screen must say so.
	case unverified
	/// The id in the link matches a finding this device already stores. `localTitle` comes from the
	/// **store**, never the link, so the one piece of text that branch renders is verified.
	case owned(localTitle: String)

	/// - Parameters:
	///   - payloadId: the id carried by the link, absent when the sender's app dropped it to fit.
	///   - storedTitle: the local lookup — `nil` when this device has no such finding.
	///
	/// A link with no id can never resolve to ``owned``: an absent id is not evidence of anything,
	/// and guessing by title would let a stranger claim the recipient's own work by copying its name.
	static func resolve(payloadId: UUID?, storedTitle: (UUID) -> String?) -> Self {
		guard let payloadId, let title = storedTitle(payloadId) else { return .unverified }
		return .owned(localTitle: title)
	}
}

// MARK: - What the unverified layout contains

/// The blocks the unverified card renders, in order.
///
/// This is the layout's **single source of truth**, not a description of it: the body iterates this
/// array. The point is the absent cases. `Finding.gps_` is free-typed text that nothing in this app
/// auto-populates, so most findings carry no coordinate at all and the no-map layout is the primary
/// one — and "no coordinate" must mean *no block*, not an empty map frame or a reserved gap.
enum SharedFindingSection: Hashable {
	case provenance
	case title
	case detection
	case author
	case date
	case page
	case box
	case map

	static func layout(for payload: FindingShareLink.Payload) -> [SharedFindingSection] {
		// Provenance leads, unconditionally. It is the only claim on this screen that is true
		// regardless of what the link contained.
		var sections: [SharedFindingSection] = [.provenance, .title]
		if detectionText(for: payload) != nil { sections.append(.detection) }
		if payload.author != nil { sections.append(.author) }
		if date(for: payload) != nil { sections.append(.date) }
		if payload.page != nil { sections.append(.page) }
		// Directly after the page, because it qualifies it: the page plus where on it is the whole
		// locator for a detection that is not on a map (AIA-0657).
		if payload.box != nil { sections.append(.box) }
		if payload.coordinate != nil { sections.append(.map) }
		return sections
	}

	/// The detection chip's text, or `nil` when the link carried neither half of it. Shared by
	/// ``layout(for:)`` and the row that renders it, so the two can never disagree about whether the
	/// block exists.
	///
	/// Not localized: the class is model vocabulary, and the percent already travels whole.
	static func detectionText(for payload: FindingShareLink.Payload) -> String? {
		switch (payload.detectionClass, payload.confidencePercent) {
		case let (detectionClass?, percent?): return "\(detectionClass) · \(percent)%"
		case let (detectionClass?, nil): return detectionClass
		case let (nil, percent?): return "\(percent)%"
		case (nil, nil): return nil
		}
	}

	/// Resolves the link's day-precision date into something renderable.
	///
	/// Built on an explicit Gregorian/UTC calendar — the same one ``FindingShareLink`` parses with —
	/// so a link written in one region resolves to the same day in another. `Calendar.date(from:)`
	/// fills in whatever a partial `DateComponents` omits rather than failing, so the three fields
	/// are required explicitly; without that check a link carrying only a year would render as the
	/// 1st of January, which is a date nobody sent.
	static func date(for payload: FindingShareLink.Payload) -> Date? {
		guard let components = payload.date,
		      components.year != nil, components.month != nil, components.day != nil
		else { return nil }
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
		return calendar.date(from: components)
	}

	/// The coordinate as text, beside the map rather than instead of it: a map pin is invisible to
	/// VoiceOver and useless to anyone who wants to paste the numbers somewhere else.
	///
	/// Five decimals matches what the link carries; `String(format:)` without a locale keeps the
	/// decimal point a point, so the value stays copy-pasteable into any mapping tool.
	static func coordinateText(_ coordinate: FindingShareLink.Coordinate) -> String {
		String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
	}
}

// MARK: - Presentation

extension View {
	/// Puts a received shared finding above everything else in the scene.
	///
	/// Applied at the scene root and **last**, so the card outranks the gates and the two overlays
	/// that already sit outside them. See the call site in `MLBrowser.swift`.
	func sharedFindingPresentation(_ appState: AppState) -> some View {
		modifier(SharedFindingHost(appState: appState))
	}
}

/// The host that bridges `SharedFindingState` into the view tree.
///
/// A separate `View` rather than an inline `.overlay` because `sharedFinding` is a nested
/// `ObservableObject`: it does not republish through `AppState`, so a link arriving would never
/// redraw a body that only observed the parent. Observing it here is what makes the presentation
/// reactive at all — the same reason `AnalyticsChoiceGate` is its own observed view.
private struct SharedFindingHost: ViewModifier {
	let appState: AppState
	@ObservedObject private var state: SharedFindingState

	init(appState: AppState) {
		self.appState = appState
		self.state = appState.sharedFinding
	}

	func body(content: Content) -> some View {
		content.overlay {
			// `isReady` gates only the *presentation*, never the buffering: a link that arrives during
			// launch waits in `SharedFindingState` and appears when the app is up. Presenting over the
			// launch spinner would also run the ownership lookup against a store that is still opening.
			if let pending = state.pending, appState.isReady {
				SharedFindingCard(pending: pending)
					// Injected explicitly. `SharedFindingView` reads `AppState` from the environment,
					// and at the scene root nothing has put it there — `ContentView` used to. A missing
					// `@EnvironmentObject` is a crash, not a blank view, so this line is load-bearing
					// rather than tidy. Same reason `.screenshotReportOffer` above takes its
					// dependencies as arguments.
					.environmentObject(appState)
					.transition(.opacity)
			}
		}
	}
}

/// The dimmed backdrop and the card on it.
///
/// Replaces an opaque, full-bleed screen. On a phone that read as a screen; in a Mac window it was a
/// mostly-empty page with a few rows stranded in the top-left corner. The visual target is a sheet;
/// the *mechanism* must not be one, for the auto-dismiss reason above.
private struct SharedFindingCard: View {
	let pending: SharedFindingState.Pending

	@EnvironmentObject private var appState: AppState

	var body: some View {
		ZStack {
			// Deliberately **not** tappable to dismiss. Dismissal clears the buffered link for the
			// session, and a stray tap on the dim would discard a stranger's finding with no way back
			// to it except the original link. Done is the only exit, and it is always on screen.
			Color.black.opacity(0.35)
				.ignoresSafeArea()

			SharedFindingView(pending: pending)
				.frame(maxWidth: 520)
				.background(
					RoundedRectangle(cornerRadius: 20, style: .continuous)
						.fill(Color(uiColor: .systemBackground))
				)
				.clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
				.shadow(radius: 24, y: 8)
				.padding(24)
		}
		// Without this VoiceOver walks straight through the dim into the paywall behind it, which
		// would be an accessibility regression shipped inside a feature about being readable.
		.accessibilityAddTraits(.isModal)
	}
}

/// Carries the card content's measured height up to the frame that caps it.
private struct SharedFindingContentHeight: PreferenceKey {
	static let defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = max(value, nextValue())
	}
}

// MARK: - The screen

/// The read-only screen shown when a shared finding link is opened.
///
/// ## It creates nothing
/// No `Finding` is written, ever. The only Core Data access is the read-only ownership lookup in
/// ``resolve()``. The one action that does touch persistent state is "open the original page", and
/// that is ordinary browsing — see ``SharedFindingView/openPage(_:)``.
///
/// ## It never navigates by itself
/// Every departure from this screen is a button the user pressed. A link is an unauthenticated
/// instruction from a stranger; the app acting on one unasked is the whole class of bug this screen
/// exists to avoid.
struct SharedFindingView: View {
	let pending: SharedFindingState.Pending

	@EnvironmentObject private var appState: AppState

	/// `nil` until the ownership lookup has run. Held in state rather than computed in `body` so the
	/// fetch happens once per link instead of once per render pass.
	@State private var presentation: SharedFindingPresentation?

	var body: some View {
		// Sized to its content, not to the window. The card's container caps the width and the
		// scroll view below caps the height, so a two-row finding is a small card rather than a
		// full-bleed page with its content stranded in the corner — which is exactly what a
		// `maxHeight: .infinity` here would reproduce, only now with a tint behind it.
		VStack(spacing: 0) {
			// The header — and with it the way out — is rendered unconditionally, *outside* the
			// `presentation` check. A state in which this card is on screen without a Done button is
			// a card the user cannot leave. Gating it on the ownership lookup would make the escape
			// hatch depend on a Core Data fetch having succeeded, and "a link never leaves the user
			// on a blank screen" is an acceptance criterion rather than a nicety.
			header
			Divider()
			ScrollView {
				bodyContent
					.background(
						GeometryReader { geometry in
							Color.clear.preference(key: SharedFindingContentHeight.self, value: geometry.size.height)
						}
					)
			}
			// **Measured, not proposed.** A `ScrollView` is greedy along its scroll axis: given
			// `.frame(maxHeight: 560)` it takes all 560 whatever it holds, so a two-line "we could not
			// read this link" card came out ~600pt tall with dead space under it — the very thing the
			// card layout replaced. Reading the content's own height and framing to `min(that, cap)`
			// is what actually shrinks it, while long findings still scroll at the cap.
			.frame(height: min(contentHeight, 560))
			.onPreferenceChange(SharedFindingContentHeight.self) { contentHeight = $0 }
		}
		.onAppear { resolve() }

		// A second link can replace the first while this screen is up (`SharedFindingState` keeps
		// the newest), and the new one may belong to the recipient when the old one did not.
		.onChange(of: pending) { _, _ in resolve() }
	}

	@State private var contentHeight: CGFloat = 0

	/// The card's scrolling content, extracted so its height can be measured.
	@ViewBuilder
	private var bodyContent: some View {
		switch pending {
				case .unreadable:
					SharedFindingUnreadableView()
				case .finding(let payload):
					switch presentation {
					case .unverified:
						SharedFindingUnverifiedView(payload: payload, onOpenPage: openPage)
							// Identity tied to the payload, so a second link gets a FRESH view rather
							// than SwiftUI reusing the first one. Without this, two pieces of state
							// outlive the swap and both are wrong: `isMapShown` stays true, so the
							// next link mounts a map with no tap — defeating the privacy property
							// this screen exists to keep — and `Map(initialPosition:)` only reads its
							// region at mount, so that map keeps showing the PREVIOUS finding's
							// location under the new finding's coordinates. Found by driving two
							// links in succession on a simulator; no unit test would have seen it.
							.id(payload)
					case .owned(let localTitle):
						SharedFindingOwnedView(localTitle: localTitle, onOpenFindings: openOwnFinding)
					case nil:
						// One runloop at most, until `onAppear` resolves ownership.
						ProgressView()
							.padding(40)
					}
				}
	}

	/// The card's own title bar. A `NavigationStack` would give the same thing, but a navigation bar
	/// inside a 520pt card reads as a screen someone forgot to finish, and the stack brought a whole
	/// navigation context along for one title and one button.
	private var header: some View {
		HStack {
			Text(L10n.Finding.Shared.title)
				.font(.headline)
			Spacer(minLength: 12)
			Button(L10n.Common.done) { dismiss() }
				.buttonStyle(.borderless)
				.testability(Testability.Button.sharedFindingDismiss)
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 14)
	}

	// MARK: - Actions

	private func resolve() {
		guard case .finding(let payload) = pending else {
			presentation = nil
			return
		}
		presentation = .resolve(payloadId: payload.id) { entityId in
			appState.findingRepository.storedFindingTitle(entityId)
		}
	}

	/// The **only** place the pending link is cleared, and only ever from a control the user pressed.
	/// A failed or deferred presentation must never call this: the buffer holds a link for the whole
	/// session precisely so a link that arrived behind a paywall or a sheet is not silently lost.
	private func dismiss() {
		appState.sharedFinding.dismiss()
	}

	/// Browses to the page the link named, then closes this screen.
	///
	/// The route is `chromeState.pageToOpen` rather than a direct `browserState.userLoadRequested`
	/// call, and that is load-bearing: the request that actually reaches the `WKWebView` is
	/// `WebScreen`'s own `loadRequest` state, which nothing outside that view can set.
	/// `WebScreen.openRequested(_:)` — the receiver of `pageToOpen` — calls `userLoadRequested`
	/// itself, so this takes exactly the same intent path as the findings list's "Open Page", while
	/// a URL handed straight to `userLoadRequested` from here would move the address bar and load
	/// nothing.
	///
	/// **This does persist a `WebVisit`**, via `VisitTrailRecorder`, and that is correct: the user
	/// asked for a page and got one, which is ordinary browsing and already recorded everywhere else
	/// in the app. The read-only promise of this screen is narrower and exact — *no `Finding` is
	/// created from a shared link.*
	private func openPage(_ page: URL) {
		appState.chromeState.mode = .web
		// Close the drawer first. This screen is an overlay above everything, so it can be dismissed
		// while the drawer — or the findings sheet it presents — is still open underneath, and the
		// page would then load out of sight behind them. The findings list's own "Open Page" does the
		// same thing for the same reason.
		appState.chromeState.presentedSideMenu = false
		// First run stages the onboarding tour's demo page (`AppState`), and `WebScreen` consumes it
		// in the same appear pass that delivers the latch below — so without this the two race and
		// the page the user actually asked for may lose. A stranger who installed the app *from a
		// shared link* is the case this feature exists for, and an explicit tap outranks a default:
		// the tour still runs, it simply starts on the page they came for. Decided by the product
		// owner (AIA-0657).
		appState.settings.onboardingInitialPage = nil
		appState.chromeState.pageToOpen = page
		dismiss()
	}

	/// Takes the recipient to their own copy.
	///
	/// It opens the findings **inventory**, not the finding: `FindingsListView` owns its
	/// `NavigationStack` privately and exposes no selection — its only external input is an
	/// "open this page" callback — so landing on a specific row would mean threading a
	/// `NavigationPath` binding out of it. That is a larger change than this screen justifies, and
	/// deep navigation is out of scope here.
	///
	/// The findings sheet is presented by `DrawerContent`, which is not mounted while the drawer is
	/// closed — hence the latch on chrome state rather than a call.
	private func openOwnFinding() {
		appState.chromeState.presentsFindings = true
		appState.chromeState.presentedSideMenu = true
		dismiss()
	}
}

// MARK: - Someone else's finding

/// The unverified card. Deliberately free of `AppState`: it renders a value and reports one intent,
/// which is what makes it previewable and what keeps the "no coordinate → no map" layout rule
/// checkable in isolation.
struct SharedFindingUnverifiedView: View {
	let payload: FindingShareLink.Payload
	let onOpenPage: (URL) -> Void

	/// Whether the recipient has asked for the map. Starts false so opening a link fetches no tiles
	/// for a sender-chosen coordinate — see ``mapBlock``.
	@State private var isMapShown = false

	/// Deliberately **not** a `ScrollView`. Since AIA-0657 this is presented inside the card's own
	/// scroll view, and a scroll view nested in another along the same axis leaves the inner one
	/// inert while confusing the height the outer one measures.
	var body: some View {
		VStack(alignment: .leading, spacing: 20) {
			ForEach(SharedFindingSection.layout(for: payload), id: \.self) { section in
				row(section)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(20)
	}

	@ViewBuilder
	private func row(_ section: SharedFindingSection) -> some View {
		switch section {
		case .provenance:
			provenance
		case .title:
			// `Text(_: some StringProtocol)`, not the `LocalizedStringKey` overload — this is the
			// sender's own words and must never be run through a lookup table.
			Text(payload.title)
				.font(.title2.bold())
				.foregroundStyle(.primary)
		case .detection:
			if let text = SharedFindingSection.detectionText(for: payload) {
				Text(verbatim: text)
					.font(.caption.weight(.semibold))
					.padding(.horizontal, 10)
					.padding(.vertical, 4)
					.background(Color.accentColor.opacity(0.18), in: Capsule())
					.foregroundStyle(Color.accentColor)
			}
		case .author:
			if let author = payload.author {
				detail(L10n.Finding.author, value: author, systemImage: "person")
			}
		case .date:
			if let date = SharedFindingSection.date(for: payload) {
				LabeledContent {
					Text(date, format: Date.FormatStyle(date: .abbreviated))
						.foregroundStyle(.primary)
				} label: {
					Label(L10n.Configuration.created, systemImage: "calendar")
						.foregroundStyle(.secondary)
				}
				.font(.callout)
			}
		case .page:
			pageBlock
		case .box:
			boxBlock
		case .map:
			mapBlock
		}
	}

	/// The one block that is always here, and the reason this screen can be trusted to be honest
	/// about itself.
	///
	/// Associated Domains authenticates the **domain** that served the link, never the fields inside
	/// it. Anyone willing to type a URL can put any title, any author's name and any coordinate on
	/// this screen, so it says so in as many words rather than presenting a stranger's claims with
	/// the authority of the recipient's own findings.
	private var provenance: some View {
		HStack(alignment: .top, spacing: 12) {
			Image(systemName: "exclamationmark.shield")
				.font(.title3)
				.foregroundStyle(.orange)
			VStack(alignment: .leading, spacing: 4) {
				Text(L10n.Finding.Shared.unverifiedTitle)
					.font(.subheadline.bold())
				Text(L10n.Finding.Shared.unverifiedMessage)
					.font(.footnote)
					.foregroundStyle(.secondary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(14)
		.background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.accessibilityElement(children: .combine)
		.testability(Testability.View.sharedFindingProvenance)
	}

	@ViewBuilder
	private var pageBlock: some View {
		if let page = payload.page {
			VStack(alignment: .leading, spacing: 10) {
				detail(L10n.Finding.page, value: page.host ?? page.absoluteString, systemImage: "globe")
				Button {
					onOpenPage(page)
				} label: {
					Label(L10n.Finding.Shared.openPage, systemImage: "safari")
				}
				.buttonStyle(.bordered)
				.testability(Testability.Button.sharedFindingOpenPage)
			}
		}
	}

	/// Where on the page the detection sat.
	///
	/// This is the block that makes a link *locate* rather than merely describe, for the case a
	/// coordinate never covers: a detection on an ordinary page, where the page plus the place on it
	/// is the whole answer. `Finding.gps_` is hand-typed and usually empty, so this is the common
	/// case and the map block is the exception.
	///
	/// **No imagery is involved and none could be.** Page snapshots never leave the device (AGENTS
	/// §10), so the recipient gets a diagram of a page rather than the page: position and area are
	/// exact, the drawn rectangle's proportions are indicative, and the description below says only
	/// the two things that are true.
	@ViewBuilder
	private var boxBlock: some View {
		if let box = payload.box {
			VStack(alignment: .leading, spacing: 8) {
				Label(L10n.Finding.Shared.Where.title, systemImage: "viewfinder")
					.font(.callout)
					.foregroundStyle(.secondary)
				SharedFindingBoxDiagram(box: box)
			}
			.accessibilityElement(children: .ignore)
			.accessibilityLabel(L10n.Finding.Shared.Where.accessibility(
				box.x.formatted(.percent.precision(.fractionLength(0))),
				box.y.formatted(.percent.precision(.fractionLength(0))),
				box.areaFraction.formatted(.percent.precision(.fractionLength(0)))
			))
		}
	}

	/// Rendered only when the link actually carried a coordinate — the exception, not the rule: the
	/// finding's GPS field is free text nothing auto-populates, so most links have none. When there
	/// is none this block is absent from ``SharedFindingSection/layout(for:)`` entirely, leaving no
	/// empty frame and no gap where a map would have been.
	/// The coordinate, always as text; the map itself only once the recipient asks for it.
	///
	/// **Mounting `Map` fetches tiles**, and the coordinate it centres on was chosen by whoever wrote
	/// the link. Rendering it on arrival would mean opening a stranger's link silently causes this
	/// device to make a network request parameterised by that stranger's input. This feature already
	/// refuses that trade once — the shared link travels as a `String` rather than a `URL` precisely
	/// so `LinkPresentation` cannot fetch anything on the sharer's behalf — and it would be
	/// inconsistent to accept it here on the recipient's side, where the input is less trusted.
	///
	/// The text is the part the acceptance criteria actually need on arrival; the map is one tap away.
	@ViewBuilder
	private var mapBlock: some View {
		if let coordinate = payload.coordinate {
			VStack(alignment: .leading, spacing: 10) {
				detail(L10n.Finding.gps, value: SharedFindingSection.coordinateText(coordinate), systemImage: "location")
				if isMapShown {
					let center = CLLocationCoordinate2D(
						latitude: coordinate.latitude,
						longitude: coordinate.longitude
					)
					// Display only. Nothing here asks for location permission or reads the device's
					// position — the app has no location entitlement and must not acquire one to show
					// a point that arrived in a URL. `interactionModes: []` keeps it a picture rather
					// than a map the user can wander off into.
					Map(
						initialPosition: .region(
							MKCoordinateRegion(center: center, latitudinalMeters: 800, longitudinalMeters: 800)
						),
						interactionModes: []
					) {
						Marker(payload.title, coordinate: center)
					}
					.frame(height: 200)
					.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
					// The coordinate is already above as text; a pin has nothing to read out.
					.accessibilityHidden(true)
				} else {
					Button {
						isMapShown = true
					} label: {
						Label(L10n.Finding.Shared.showOnMap, systemImage: "map")
					}
					.buttonStyle(.bordered)
					.testability(Testability.Button.sharedFindingShowMap)
				}
			}
		}
	}

	/// One labelled row. `value` is always link-supplied text, so it goes through the
	/// non-localizing `Text` initializer.
	private func detail(_ label: String, value: String, systemImage: String) -> some View {
		LabeledContent {
			Text(value)
				.foregroundStyle(.primary)
				.multilineTextAlignment(.trailing)
		} label: {
			Label(label, systemImage: systemImage)
				.foregroundStyle(.secondary)
		}
		.font(.callout)
	}
}

// MARK: - Where on the page

/// A page-shaped frame with the detection drawn inside it to scale.
///
/// ## Why the frame is a fixed ratio and not the page's
/// The box is normalized against the captured view, whose aspect ratio does **not** travel — four
/// numbers were worth their characters, a fifth for the shape was not. So position and area are
/// faithful and the rectangle's proportions are indicative. That is why nothing here, or in the
/// accessibility text beside it, claims the drawing is proportional.
///
/// ## Why it does not mirror
/// Pinned left-to-right. This is a picture of a page rather than a run of text: the box's `x` is a
/// distance from the *page's* left edge, and mirroring the diagram under `ar`, `he` or `fa` would
/// put the detection on the wrong side of the page it is describing.
struct SharedFindingBoxDiagram: View {
	let box: FindingShareLink.Box

	/// Neutral, and deliberately neither a phone's viewport nor a desktop's.
	private static let aspect: CGFloat = 3.0 / 2.0

	/// A box can be a hairline at this scale — a small detection on a large page — so the drawn rect
	/// has a floor. It marks *where*; the size is carried honestly by the text.
	private static let minimumDrawn: CGFloat = 4

	var body: some View {
		GeometryReader { geometry in
			let size = geometry.size
			let width = max(box.width * size.width, Self.minimumDrawn)
			let height = max(box.height * size.height, Self.minimumDrawn)
			ZStack(alignment: .topLeading) {
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.fill(Color.secondary.opacity(0.12))
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
				Rectangle()
					.strokeBorder(.red, lineWidth: 2)
					.frame(width: width, height: height)
					// Clamped so a box flush against an edge draws inside the frame rather than
					// half-outside it, which reads as a rendering fault rather than as a location.
					.offset(
						x: min(box.x * size.width, size.width - width),
						y: min(box.y * size.height, size.height - height)
					)
			}
		}
		.aspectRatio(Self.aspect, contentMode: .fit)
		.frame(maxWidth: 240, alignment: .leading)
		.environment(\.layoutDirection, .leftToRight)
		.accessibilityHidden(true)
		.testability(Testability.View.sharedFindingBoxDiagram)
	}
}

// MARK: - A link we could not read

/// Shown when a link matched this app's association but its payload would not parse.
///
/// This screen exists because of an asymmetry that is easy to miss. The association file matches on
/// path alone, so iOS opens the app for **any** `/f` link — including one a messaging platform
/// truncated mid-fragment, one that was hand-edited, or one written by a future version of the app.
/// The landing page has copy for exactly this situation, but the landing page is what the user does
/// *not* get: having the app installed is precisely what routes them here instead. Without this
/// screen the app would open and do nothing, which reads as the app being broken rather than the
/// link being damaged.
struct SharedFindingUnreadableView: View {
	var body: some View {
		VStack(spacing: 16) {
			Spacer()
			Image(systemName: "link.badge.plus")
				.font(.system(size: 44))
				.foregroundStyle(.secondary)
				.accessibilityHidden(true)
			Text(L10n.Finding.Shared.Unreadable.title)
				.font(.title3.bold())
				.multilineTextAlignment(.center)
			Text(L10n.Finding.Shared.Unreadable.message)
				.font(.footnote)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
			Spacer()
		}
		.padding(24)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.testability(Testability.View.sharedFindingUnreadable)
	}
}

// MARK: - Their own finding

/// Shown when the link's id matches a finding this device already stores.
///
/// Deliberately renders **nothing** that came from the link — not the title, not the author, not the
/// coordinate. The recipient already owns this finding, the local copy is the truth, and showing the
/// link's version beside it would put unverified text on the one screen that carries no provenance
/// warning.
struct SharedFindingOwnedView: View {
	let localTitle: String
	let onOpenFindings: () -> Void

	var body: some View {
		VStack(spacing: 16) {
			Spacer()
			Image(systemName: "checkmark.seal")
				.font(.system(size: 44))
				.foregroundStyle(.tint)
			Text(L10n.Finding.Shared.Owned.title)
				.font(.title3.bold())
			Text(localTitle)
				.font(.headline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
			Text(L10n.Finding.Shared.Owned.message)
				.font(.footnote)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
			Button {
				onOpenFindings()
			} label: {
				Label(L10n.Finding.Shared.Owned.open, systemImage: "archivebox")
			}
			.buttonStyle(.borderedProminent)
			.testability(Testability.Button.sharedFindingOpenOwn)
			Spacer()
		}
		.padding(24)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
}

#if DEBUG
// MARK: - Previews

/// The primary case: no coordinate, therefore no map and no gap where one would be.
#Preview("Shared — no coordinate") {
	NavigationStack {
		SharedFindingUnverifiedView(
			payload: FindingShareLink.Payload(
				title: "Overgrown rampart on the north ridge",
				detectionClass: "earthwork",
				confidencePercent: 82,
				page: URL(string: "https://example.org/maps/ridge"),
				author: "M. Novák",
				date: DateComponents(year: 2026, month: 5, day: 14)
			),
			onOpenPage: { _ in }
		)
		.navigationTitle(L10n.Finding.Shared.title)
		.navigationBarTitleDisplayMode(.inline)
	}
}

#Preview("Shared — with coordinate") {
	NavigationStack {
		SharedFindingUnverifiedView(
			payload: FindingShareLink.Payload(
				title: "Ditch segment",
				detectionClass: "ditch",
				confidencePercent: 61,
				coordinate: FindingShareLink.Coordinate(latitude: 48.8, longitude: 19.53),
				author: "M. Novák"
			),
			onOpenPage: { _ in }
		)
		.navigationTitle(L10n.Finding.Shared.title)
		.navigationBarTitleDisplayMode(.inline)
	}
}

#Preview("Shared — already yours") {
	NavigationStack {
		SharedFindingOwnedView(localTitle: "Overgrown rampart on the north ridge", onOpenFindings: {})
			.navigationTitle(L10n.Finding.Shared.title)
			.navigationBarTitleDisplayMode(.inline)
	}
}
#endif
