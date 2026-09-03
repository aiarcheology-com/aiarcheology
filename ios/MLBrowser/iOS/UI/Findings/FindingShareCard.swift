//
//  FindingShareCard.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 13.06.26.
//

import SwiftUI

/// Orientation of the shareable card. Portrait suits Instagram/feed posts (4:5);
/// landscape suits link cards on Facebook / X (~1.9:1).
enum ShareCardOrientation: String, CaseIterable, Identifiable {
	case portrait
	case landscape

	var id: String { rawValue }

	/// Layout size in points. Rendered at the display scale (≥3) for a crisp,
	/// social-ready PNG.
	///
	/// Enlarged for AIA-0650, keeping both aspect ratios exactly (4:5 and ~1.9:1 — the whole reason
	/// the two orientations exist). The QR printed on the card cannot shrink: it needs roughly 3px
	/// per module to survive being photographed off a screen, which pins it at 64pt on a ≥3×
	/// canvas. Growing the card instead makes that fixed code a smaller *fraction* of the metadata
	/// block — in portrait it drops from about 36% of that block's height to 25% — which is what
	/// makes room for it beside the text rather than on top of it.
	/// Landscape grew again for AIA-0657, and by measurement rather than preference. The link badge
	/// is now a sibling of the text rather than an overlay on it, so it *reserves* its width — and at
	/// 640pt the metadata block had 139.6pt left for the rows, while the host row (the degraded floor
	/// the ticket forbids losing) needs about 149pt for a domain like `www.openstreetmap.org`.
	/// `FindingShareCardLayoutTests.test_theHostRowFitsBesideTheBadgeInBothOrientations` is that
	/// measurement, and it failed at 640×336 before this change.
	///
	/// 760×399 is the same ratio to the pixel — 640/336 and 760/399 are both exactly 40/21 — which
	/// matters because the two orientations exist *to be* 4:5 and ~1.9:1 for the feeds that crop to
	/// them. 760×400 would have been a quietly different card.
	var size: CGSize {
		switch self {
		case .portrait: return CGSize(width: 480, height: 600)
		case .landscape: return CGSize(width: 760, height: 399)
		}
	}

	/// The image area within the card (the rest is the metadata block).
	var imageSlotSize: CGSize {
		switch self {
		case .portrait: return CGSize(width: size.width, height: size.height * 0.58)
		case .landscape: return CGSize(width: size.width * 0.56, height: size.height)
		}
	}
}

/// A Sendable value snapshot of a finding for sharing — built on the MainActor so
/// the composer/card never touch Core Data (and never cross the sheet boundary
/// with a managed object). Identifiable so it can drive `.sheet(item:)`.
struct FindingShareSubject: Identifiable {
	let id: UUID
	let image: UIImage?
	/// The detection in `image`'s own coordinates — what the card draws over the picture.
	let normalizedBox: CGRect
	/// The detection on the captured view, before any crop was baked into `image` — what a share
	/// link may state, since a recipient has no crop to resolve `normalizedBox` against.
	/// `.zero` when the finding never recorded one (AIA-0761).
	let captureNormalizedBox: CGRect
	let title: String
	let label: String?
	let note: String?
	/// The finder's credit, nil when it was left blank. Rendered as a byline only when present —
	/// a shared card never invents an "Unknown" author (AIA-0651).
	let author: String?
	let gps: String?
	let detectionClass: String?
	let confidence: Double
	let host: String?
	let date: Date?
	let page: URL?

	@MainActor init(_ finding: Finding) {
		id = finding.entityId
		image = FindingScreenshotStore.load(filename: finding.screenshotFilename)
		normalizedBox = finding.normalizedBox
		captureNormalizedBox = finding.captureNormalizedBox
		title = finding.displayTitle
		label = finding.label_
		note = finding.note_
		author = finding.author
		gps = finding.gps_
		detectionClass = finding.detectionClass
		confidence = finding.detectionConfidence
		host = finding.page?.host
		date = finding.creationDate_
		page = finding.page
	}

	/// The value-level initializer. The Core Data one above is how the app builds a subject; this is
	/// how a test or a preview builds one without a managed object context, which is what makes the
	/// subject → link-payload mapping checkable on its own (AIA-0650).
	init(
		id: UUID,
		image: UIImage? = nil,
		normalizedBox: CGRect = .zero,
		captureNormalizedBox: CGRect = .zero,
		title: String,
		label: String? = nil,
		note: String? = nil,
		author: String? = nil,
		gps: String? = nil,
		detectionClass: String? = nil,
		confidence: Double = 0,
		host: String? = nil,
		date: Date? = nil,
		page: URL? = nil
	) {
		self.id = id
		self.image = image
		self.normalizedBox = normalizedBox
		self.captureNormalizedBox = captureNormalizedBox
		self.title = title
		self.label = label
		self.note = note
		self.author = author
		self.gps = gps
		self.detectionClass = detectionClass
		self.confidence = confidence
		self.host = host
		self.date = date
		self.page = page
	}

	/// The same subject with its coordinate withheld.
	///
	/// One function, because the coordinate leaves the app by two routes — printed on the card and
	/// carried inside the share link — and a sender who turns the location off means both. Gating
	/// the card's row alone would produce a picture with no coordinate on it and a link that still
	/// names the spot, which is worse than not offering the choice.
	///
	/// The page address is deliberately untouched: a geoportal URL can itself carry a viewport, and
	/// that trade-off already has its own control (``FindingShareComposer/sharesFullAddress``),
	/// which prints the exact address before anything is sent.
	func withholdingLocation() -> FindingShareSubject {
		FindingShareSubject(
			id: id,
			image: image,
			normalizedBox: normalizedBox,
			captureNormalizedBox: captureNormalizedBox,
			title: title,
			label: label,
			note: note,
			author: author,
			gps: nil,
			detectionClass: detectionClass,
			confidence: confidence,
			host: host,
			date: date,
			page: page
		)
	}
}

/// The composed, shareable card. Themed via the ambient color scheme (set
/// explicitly by the renderer, since `ImageRenderer` ignores the environment)
/// and laid out per orientation. Fixed size so the rendered pixel size is
/// deterministic and social-ready.
struct FindingShareCard: View {
	let subject: FindingShareSubject
	let orientation: ShareCardOrientation
	/// Composer-driven framing of the cover-filled image (1 = fit-to-fill).
	var zoom: CGFloat = 1
	var offset: CGSize = .zero
	/// The address + QR sticker, or `nil` (AIA-0650).
	///
	/// `nil` is the feature-flag-off path and must render **nothing**: with `isFindingShareLinkEnabled`
	/// off, the card this produces is byte-identical to the one the app shipped before the link
	/// existed. It is also the toggle-off path, and the "no compact link could be built" path.
	var link: FindingShareCardLink?

	@Environment(\.colorScheme) private var colorScheme

	var body: some View {
		Group {
			switch orientation {
			case .portrait:
				VStack(spacing: 0) {
					imageSlot
					metadata
				}
			case .landscape:
				HStack(spacing: 0) {
					imageSlot
					metadata
				}
			}
		}
		.frame(width: orientation.size.width, height: orientation.size.height)
		.background(background)
	}

	// MARK: - Pieces

	private var imageSlot: some View {
		let slot = orientation.imageSlotSize
		return ZStack(alignment: .topTrailing) {
			if let image = subject.image {
				// Cover-fill (image always fills the slot — no letterbox), then the
				// composer's zoom/pan frames it. The highlight transforms with it.
				let cover = slot.coverSize(for: image.size)
				let rect = subject.normalizedBox.visionRect(in: cover)
				ZStack {
					Image(uiImage: image)
						.resizable()
						.frame(width: cover.width, height: cover.height)
					Rectangle()
						.stroke(.red, lineWidth: 2 / zoom)
						.frame(width: rect.width, height: rect.height)
						.position(x: rect.midX, y: rect.midY)
				}
				.frame(width: cover.width, height: cover.height)
				.scaleEffect(zoom)
				.offset(offset)
				.frame(width: slot.width, height: slot.height)
				.clipped()
			} else {
				Color.black.opacity(colorScheme == .dark ? 0.35 : 0.06)
				Image(systemName: "photo")
					.font(.largeTitle)
					.foregroundStyle(.secondary)
			}
			// App icon + name so viewers can tell where the finding was captured.
			if let icon = Bundle.main.appIcon {
				VStack(spacing: 4) {
					Image(uiImage: icon)
						.resizable()
						.scaledToFill()
						.frame(width: 40, height: 40)
						.clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
						.overlay(
							RoundedRectangle(cornerRadius: 9, style: .continuous)
								.strokeBorder(.white.opacity(0.7), lineWidth: 1)
						)
					// The app's own name (brand, not localized) from the bundle.
					Text(verbatim: Bundle.main.appName)
						.font(.caption2.weight(.semibold))
						.foregroundStyle(.white)
				}
				.shadow(radius: 3, y: 1)
				.padding(10)
			}
		}
		.frame(width: slot.width, height: slot.height)
		.clipped()
	}

	/// The text block and, when there is one, the link badge beside it.
	///
	/// ## Why the badge is a sibling and not an overlay
	/// It used to be `.overlay(alignment: .bottomTrailing)` applied *before* the expanding
	/// `.frame(…, alignment: .topLeading)`, so it anchored to the intrinsically-sized text block
	/// rather than to the metadata block — below the rows and left of centre in portrait, and not
	/// quite in the corner in landscape (AIA-0657). Reordering the modifiers would have fixed the
	/// anchor and left the overlap: an overlay draws *on top of* the rows, so a long note or host
	/// would run underneath the code.
	///
	/// As a sibling in an `HStack(alignment: .bottom)` the overlap is not merely absent, it is
	/// unrepresentable — the text column's width excludes the badge by construction, at any row
	/// count from two to seven.
	///
	/// ## Two properties, both load-bearing
	/// - `.frame(maxWidth: .infinity, alignment: .leading)` on the text column: a `VStack` sizes to
	///   its widest child, so without this the badge sits immediately right of the *longest row*
	///   instead of flush to the block's trailing edge — the original defect, rebuilt inside its own
	///   fix.
	/// - the trailing `Spacer(minLength: 0)`: it is what makes the column fill the block's height,
	///   and therefore what puts the `.bottom`-aligned badge on the block's floor. Without it the
	///   `HStack` collapses to its content and the outer `.topLeading` frame floats the badge in
	///   mid-block whenever the finding has few rows.
	///
	/// Two rows is the case that exercises both at once, which is why the layout test asserts there.
	private var metadata: some View {
		HStack(alignment: .bottom, spacing: 12) {
			metadataRows
				.frame(maxWidth: .infinity, alignment: .leading)

			if let link {
				FindingShareLinkBadge(link: link)
			}
		}
		.padding(16)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
	}

	/// How many lines of the note the block can actually show.
	///
	/// Reported from a build: on the landscape card the note truncated after **two** lines with the
	/// lower half of the metadata block empty. The two orientations have wildly different room, and
	/// these are the numbers that say so.
	///
	/// Measured against a finding carrying every other row — title, detection chip, byline, label,
	/// coordinate, host, date, plus seven 8pt gaps, about 200pt of content:
	///
	/// - **Landscape** has a 334×399 block, roughly 367pt of usable height, so about 165pt is free:
	///   ten caption lines with a margin for a title or a coordinate that wraps.
	/// - **Portrait** has a 480×252 block, roughly 220pt usable, so only about 20–36pt is free. Its
	///   previous cap of four lines *overflowed* that, and what a `VStack` drops when it overflows is
	///   the end — the coordinate, the host and the date, the rows the note is least entitled to take.
	///   `test_aLongNoteDoesNotCrowdOutTheCoordinate` is that measurement and it failed at four.
	///
	/// A layout-driven version was tried first — no cap at all, the note absorbing whatever slack the
	/// other rows left. It measured *worse*: `VStack` offered the flexible child a single line, so the
	/// note came out shorter than the constant it replaced. The card is a fixed size and its rows are
	/// known, so a measured constant is the honest mechanism.
	static func noteLineLimit(for orientation: ShareCardOrientation) -> Int {
		orientation == .landscape ? 10 : 2
	}

	private var metadataRows: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(subject.title)
				.font(.title3.bold())
				.foregroundStyle(.primary)
				.lineLimit(2)

			if let detectionClass = subject.detectionClass {
				// verbatim: model class vocabulary, not localizable.
				// Clamped as a Double BEFORE the conversion. `Int(_:)` traps on NaN or on anything
				// outside `Int`'s range, and `Finding.detectionConfidence` is an unconstrained Core
				// Data `Double` — so a corrupt or imported row crashed the app on *rendering the
				// card*. Exactly the trap `FindingShareEmission.percent` was rewritten to avoid;
				// this copy was one file away and still had it (found in review, AIA-0657).
				Text(verbatim: "\(detectionClass) · \(Int((min(1, max(0, subject.confidence.isFinite ? subject.confidence : 0)) * 100).rounded()))%")
					.font(.caption.weight(.semibold))
					.padding(.horizontal, 10)
					.padding(.vertical, 4)
					.background(Color.accentColor.opacity(0.18), in: Capsule())
					.foregroundStyle(Color.accentColor)
			}

			// The byline sits directly under the detection chip: it credits the finding as a whole,
			// so it reads above the per-field rows rather than among them (AIA-0651).
			if let author = subject.author {
				Label(author, systemImage: "person")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}

			if let label = subject.label {
				Label(label, systemImage: "tag")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			if let note = subject.note {
				Label {
					Text(note)
				} icon: {
					Image(systemName: "note.text")
				}
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(Self.noteLineLimit(for: orientation))
			}
			if let gps = subject.gps {
				FindingShareCoordinateRow(gps: gps)
			}

			if let host = subject.host {
				Label(host, systemImage: "globe")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			if let date = subject.date {
				Label {
					Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
				} icon: {
					Image(systemName: "calendar")
				}
				.font(.caption)
				.foregroundStyle(.secondary)
			}

			// Load-bearing: this is what makes the column fill the block, and therefore what puts the
			// badge beside it on the block's floor. See ``metadata``.
			Spacer(minLength: 0)
		}
	}

	private var background: some View {
		Color(.systemBackground)
	}
}

// MARK: - Composer

/// Pre-share options sheet: a live preview of the card with Light/Dark and
/// Portrait/Landscape toggles, then renders the chosen variant to a PNG and
/// hands it to the system share sheet — with, when `isFindingShareLinkEnabled`
/// is on and the user has not opted out, a link to the finding beside it.
struct FindingShareComposer: View {
	let subject: FindingShareSubject

	@Environment(\.dismiss) private var dismiss
	@Environment(\.displayScale) private var displayScale
	@Environment(\.colorScheme) private var systemColorScheme

	/// Observed directly rather than reached through `AppState`: a nested `ObservableObject` does not
	/// republish through its parent, so a dashboard flip would leave this sheet stale (AIA-0350).
	/// This flag is read live on purpose — it shows and hides an entry point inside a sheet, so it can
	/// be switched on the moment `link.aiarcheology.com` is verified, without waiting for cold starts.
	@EnvironmentObject private var featureFlags: FeatureFlagsState

	@State private var theme: ColorScheme = .light
	@State private var orientation: ShareCardOrientation = .portrait
	@State private var sharePayload: ActivitySharePayload?
	@State private var didSeedTheme = false

	/// **Default on, and deliberately not persisted.**
	///
	/// `theme` and `orientation` already reseed per presentation for the same reason
	/// (`didSeedTheme`). A remembered "off" would be indistinguishable from the feature never having
	/// existed: the user would turn it off once to reach Save Image, and every share they ever made
	/// afterwards would silently be an image with no way back into the app.
	@State private var includesLink = true

	/// Whether the link carries the page's whole address or only its site.
	///
	/// **Default on**, because the reduced form is what this ticket exists to fix: a geoportal keeps
	/// the view in the query string, so a site-only link lands the recipient on a homepage holding
	/// none of what was shared. The privacy cost is not hidden behind that default — the exact
	/// address is printed below the toggle before anything is posted, which is the mechanism the
	/// acceptance criteria name (AIA-0657).
	@State private var sharesFullAddress = true

	/// Whether the recorded coordinate travels with the share.
	///
	/// **Default on**, matching what the card has always printed: a finding that recorded where it
	/// is says so, and a sender who does not want that says so once, per share. Not persisted, for
	/// the same reason `includesLink` is not — a remembered "off" is indistinguishable from the
	/// coordinate never having been recorded, and the sender would have no way to tell which.
	///
	/// Only ever shown when there is a coordinate to withhold; a control over nothing is worse than
	/// no control, because it implies a location exists.
	@State private var includesLocation = true

	/// Whether the card is open on its own, at reading size.
	///
	/// The preview is a whole card scaled into a slot a few hundred points tall, so its metadata is
	/// drawn at a fraction of the size it will be posted at — a projected coordinate is legible on
	/// the exported image and not in the preview. The preview's enlarge button opens the same card
	/// in a sheet, where only the sheet limits it.
	@State private var isInspectingCard = false

	/// A phone held sideways has a sheet only a few hundred points tall, and the composer's controls
	/// — a slider, two pickers, three toggles with footnotes and the address box — are taller than
	/// that on their own.
	@Environment(\.verticalSizeClass) private var verticalSizeClass

	/// The rendered address + QR, built once per presentation. Held in state rather than computed in
	/// `body` because the preview re-renders on every frame of a pinch or a drag, and generating a QR
	/// is a Core Image round trip.
	@State private var linkArt: FindingShareCardLink?

	// Composer-driven framing of the card image (cover-fill at zoom 1).
	@State private var imageZoom: CGFloat = 1
	@State private var imageOffset: CGSize = .zero
	@GestureState private var pinch: CGFloat = 1
	@GestureState private var dragDelta: CGSize = .zero

	private static let zoomRange: ClosedRange<CGFloat> = 1...8

	var body: some View {
		NavigationStack {
			VStack(spacing: 20) {
				preview
					// A floor, and deliberately NOT a layout priority. Both children here are flexible,
					// so an equal-priority stack splits the space between them and this floor then
					// claims the difference — the card takes the floor and the controls scroll in what
					// is left. Raising the priority instead gave the card *everything*: the
					// `ScrollView` below has a minimum height of zero, so a higher-priority sibling is
					// offered the whole slot and the controls vanish (raised in review).
					//
					// A floor is needed on a PHONE for the opposite reason. Held sideways the sheet is
					// a few hundred points tall, the controls are taller than that on their own, and
					// the preview was squeezed to nothing — the card disappeared entirely and only
					// portrait showed it (reported from a build). It is smaller there because the room
					// is smaller: enough to see the card, with the rest scrolling.
					.frame(minHeight: previewFloor)
				controlsArea
			}
			.padding()
			.frame(maxHeight: .infinity, alignment: .top)
			.navigationTitle(L10n.Finding.Share.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarLeading) {
					Button(L10n.Common.cancel) { dismiss() }
						.tint(.blue)
						.testability(Testability.Button.findingShareCancel)
				}
				ToolbarItem(placement: .navigationBarTrailing) {
					Button(action: share) {
						Text(L10n.Common.share).bold()
					}
					.tint(.green)
					.testability(Testability.Button.findingShareConfirm)
				}
			}
			.activityShareSheet($sharePayload)
		}
		.roomySheet()
		.sheet(isPresented: $isInspectingCard) { cardInspector }
		.onAppear {
			// Default to the system appearance the first time only.
			if didSeedTheme.not {
				theme = systemColorScheme
				didSeedTheme = true
			}
		}
		// Keyed on the **pair**, and rebuilt unconditionally rather than only when `linkArt` is nil.
		//
		// The previous `guard enabled, linkArt == nil` made this idempotent on purpose — generating a
		// QR is a Core Image round trip and the preview re-renders on every frame of a pinch — but
		// that guard becomes exactly wrong once a second input can change the payload. With it,
		// flipping the address toggle updated the printed address row (derived from the payload) while
		// the code went on encoding the previous URL, and `share()` exported that stale code: the
		// sender would watch the privacy control appear to work and post a card whose QR still carried
		// the query. Rebuilding costs one round trip per deliberate tap, not one per frame.
		// `initial: true` covers the ordinary case of the flag already being on when the sheet opens.
		.onChange(
			of: LinkArtKey(
				isEnabled: isLinkEnabled,
				sharesFullAddress: sharesFullAddress,
				includesLocation: includesLocation
			),
			initial: true
		) { _, _ in
			linkArt = isLinkEnabled
				? FindingShareQRCode.cardLink(for: publishedSubject, pageDetail: pageDetail)
				: nil
		}
	}

	/// Opens the card at reading size.
	///
	/// The preview scales a whole card into a slot a few hundred points tall, so its metadata is
	/// drawn at a fraction of the size it will be posted at — a projected coordinate is legible on
	/// the exported image and not here. This is how it is read before posting.
	private var enlargeButton: some View {
		Button { isInspectingCard = true } label: {
			Image(systemName: "arrow.up.left.and.arrow.down.right")
				.font(.system(size: 17, weight: .semibold))
				.foregroundStyle(.primary)
				.frame(width: 44, height: 44)
				.background(.thinMaterial, in: Circle())
				.overlay(Circle().strokeBorder(.quaternary))
		}
		.buttonStyle(.plain)
		.accessibilityLabel(L10n.Finding.Share.enlarge)
		.testability(Testability.Button.findingShareEnlarge)
	}

	/// The card on its own, as large as the sheet allows.
	///
	/// Deliberately the same card view and the same subject the composer would export — not a
	/// rendering of it, and not a second layout that could drift from what is actually posted. The
	/// framing is fixed at the composer's current zoom and pan, so what is inspected is the artifact
	/// as it stands rather than a differently-framed copy of it.
	///
	/// Sized with `roomySheet` like its parent, so on iPad and Mac it opens at the same dimensions as
	/// the composer that raised it instead of dropping back to the system's form sheet.
	private var cardInspector: some View {
		NavigationStack {
			GeometryReader { geometry in
				// Fits BOTH dimensions, like the preview: a landscape card constrained on width alone
				// would stand taller than the sheet.
				let fitScale = min(
					geometry.size.width / orientation.size.width,
					geometry.size.height / orientation.size.height
				)
				FindingShareCard(
					subject: publishedSubject,
					orientation: orientation,
					zoom: clampZoom(imageZoom),
					offset: clampedOffset(imageOffset, zoom: clampZoom(imageZoom)),
					link: cardLink
				)
					.environment(\.colorScheme, theme)
					.clipShape(RoundedRectangle(cornerRadius: 16))
					.overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
					.scaleEffect(fitScale)
					.frame(width: geometry.size.width, height: geometry.size.height)
			}
			.padding()
			.navigationTitle(L10n.Finding.Share.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .navigationBarTrailing) {
					Button(L10n.Common.done) { isInspectingCard = false }
						.tint(.blue)
						.testability(Testability.Button.findingShareInspectDone)
				}
			}
		}
		.roomySheet()
	}

	/// The address control, and the address itself.
	///
	/// The row exists because of what the card cannot say: it prints only `link.aiarcheology.com`,
	/// so the code beside that text can carry a full query string with nothing on the artifact
	/// disclosing it. Everything that could ever be sensitive in a shared link is in this one string,
	/// so it is shown whole — no middle truncation, since the middle is exactly where `?token=` sits.
	private var addressChoice: some View {
		// Read once, used by both the copy button and the preview below it. `travellingAddress`
		// builds a link and re-parses it, so evaluating it per-control is wasteful — but the reason
		// it is hoisted is the criterion, not the cost: what the button copies must be exactly what
		// the row shows, and one value makes that structural instead of two evaluations agreeing.
		let address = travellingAddress
		return VStack(alignment: .leading, spacing: 6) {
			Toggle(L10n.Finding.Share.fullAddress, isOn: $sharesFullAddress)
				.testability(Testability.Toggle.findingShareFullAddress)
			Text(L10n.Finding.Share.fullAddressFootnote)
				.font(.footnote)
				.foregroundStyle(.secondary)
				// Explicit, because a greedy sibling in this column otherwise takes its height out of
				// this text's line count rather than its own.
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity, alignment: .leading)

			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 8) {
					Text(L10n.Finding.Share.addressPreview)
						.font(.caption)
						.foregroundStyle(.secondary)
					Spacer(minLength: 0)
					// Selecting the text by hand still works and is the floor; this is the one-tap
					// form, because the floor means dragging two handles across a wrapped
					// 300-character URL. Inside the address check on purpose: when no address
					// travels there is nothing to copy, so there must be no control rather than a
					// disabled one.
					if let address {
						Button {
							UIPasteboard.general.string = address.absoluteString
						} label: {
							Label(L10n.Common.copy, systemImage: "doc.on.doc")
								.labelStyle(.iconOnly)
						}
						.buttonStyle(.borderless)
						.font(.caption)
						.accessibilityLabel(L10n.Common.copy)
						.testability(Testability.Button.findingShareCopyAddress)
					}
				}
				if let address {
					// Pinned left-to-right regardless of the app's language. A URL is a
					// left-to-right string, and under `ar`, `he` or `fa` a mixed-direction host and
					// path reorder on screen — which would make the one row whose entire purpose is
					// "this is exactly what travels" display something other than what it holds.
					// Selectable so a suspicious sender can lift it out and read it elsewhere.
					// **Not** a `ScrollView`, and that was a real bug for one build: a scroll view has
					// no intrinsic height, so in this intrinsically-sized column it collapsed to
					// nothing — the address box rendered empty — while still claiming enough space to
					// squeeze the footnote above it into a single truncated line. It was added to
					// bound the 600-character worst case; the cure was worse than the disease, since
					// the usual address is two or three lines and the card preview above this is a
					// `GeometryReader` that gives up height when the controls need it.
					Text(verbatim: address.absoluteString)
						.font(.caption.monospaced())
						.textSelection(.enabled)
						.environment(\.layoutDirection, .leftToRight)
						.multilineTextAlignment(.leading)
						.fixedSize(horizontal: false, vertical: true)
						.frame(maxWidth: .infinity, alignment: .leading)
						.testability(Testability.View.findingShareAddressPreview)
				} else {
					Text(L10n.Finding.Share.addressNotIncluded)
						.font(.caption)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
			}
			.padding(8)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
		}
	}

	/// The two inputs the printed code depends on, named rather than positional.
	///
	/// `onChange(of:)` needs one `Equatable` value and Swift tuples cannot conform, so an array was
	/// the first thing that fit — and indexing it (`flags[0]`) meant the meaning of each element
	/// lived only in the reader's head, one reordering away from silently regenerating the code for
	/// the wrong reason (raised in review).
	private struct LinkArtKey: Equatable {
		let isEnabled: Bool
		let sharesFullAddress: Bool
		/// Part of the key because the code encodes the payload, and the payload carries the
		/// coordinate: without this the location toggle would clear the card's row while the printed
		/// QR went on encoding the coordinate — the same stale-artifact defect the address toggle
		/// already had, rebuilt one field over.
		let includesLocation: Bool

		var detail: FindingShareLink.PageDetail { sharesFullAddress ? .full : .siteOnly }
	}

	/// What the sender has chosen to send.
	private var pageDetail: FindingShareLink.PageDetail {
		sharesFullAddress ? .full : .siteOnly
	}

	/// The address that will actually travel — read back out of the link this composer would emit,
	/// not out of the subject it would emit it from.
	///
	/// That distinction is the whole point. `subject.page` is the browsed URL; what travels is
	/// whatever survives sanitizing, the credential strip, the drop ladder and the length budget. A
	/// preview built from the intent would be a description of what we meant to send, which is
	/// precisely the claim an acceptance criterion about credentials cannot rest on. Building the
	/// link and parsing it back makes the row a *reading of the artifact*.
	///
	/// It is an upper bound rather than an exact match for both artifacts: the QR carries the compact
	/// variant, whose ladder may reduce this same address to its host to fit. Never a different one —
	/// `FindingShareLinkTests.test_theCompactAddressIsNeverWiderThanTheFullOne` is what holds that.
	private var travellingAddress: URL? {
		guard let url = FindingShareLink.url(
			for: subject.linkPayload(pageDetail: pageDetail),
			pageDetail: pageDetail
		) else { return nil }
		return FindingShareLink.payload(from: url)?.page
	}

	/// What this composer actually publishes, as opposed to what it was handed.
	///
	/// Every consumer of the subject downstream of the toggle reads *this* — the preview, the
	/// rendered card, the printed QR and the share items — so the coordinate cannot survive in one
	/// artifact after being withheld from another.
	private var publishedSubject: FindingShareSubject {
		includesLocation ? subject : subject.withholdingLocation()
	}

	/// The live flag. Everything this feature adds — the toggle, the card art and the shared link —
	/// hangs off this one read; with it false the composer behaves exactly as it did before AIA-0650.
	private var isLinkEnabled: Bool {
		featureFlags.snapshot.isFindingShareLinkEnabled
	}

	/// The art to print on the card, or `nil` for "print nothing".
	private var cardLink: FindingShareCardLink? {
		guard isLinkEnabled, includesLink else { return nil }
		return linkArt
	}

	private var preview: some View {
		GeometryReader { geometry in
			// Fits BOTH dimensions. Scaling on width alone was fine while the card was 340x425 —
			// it fit a phone at 1:1 — but the enlarged 480x600 card scales to ~0.81 on width and
			// still stands ~487pt tall, which is taller than the old card and overlaps the zoom
			// slider below it. Constraining height too keeps the preview inside its slot at any
			// card size.
			let fitScale = min(1, min(geometry.size.width / orientation.size.width,
			                          geometry.size.height / orientation.size.height))
			let liveZoom = clampZoom(imageZoom * pinch)
			let liveOffset = clampedOffset(
				CGSize(width: imageOffset.width + dragDelta.width / fitScale,
				       height: imageOffset.height + dragDelta.height / fitScale),
				zoom: liveZoom
			)
			FindingShareCard(
				subject: publishedSubject,
				orientation: orientation,
				zoom: liveZoom,
				offset: liveOffset,
				link: cardLink
			)
				.environment(\.colorScheme, theme)
				.clipShape(RoundedRectangle(cornerRadius: 16))
				.overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
				.shadow(radius: 8, y: 4)
				.scaleEffect(fitScale)
				.frame(width: geometry.size.width, height: orientation.size.height * fitScale)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.gesture(
					SimultaneousGesture(
						MagnificationGesture()
							.updating($pinch) { value, state, _ in state = value }
							.onEnded { value in
								imageZoom = clampZoom(imageZoom * value)
								imageOffset = clampedOffset(imageOffset, zoom: imageZoom)
							},
						DragGesture()
							.updating($dragDelta) { value, state, _ in state = value.translation }
							.onEnded { value in
								imageOffset = clampedOffset(
									CGSize(width: imageOffset.width + value.translation.width / fitScale,
									       height: imageOffset.height + value.translation.height / fitScale),
									zoom: imageZoom
								)
							}
					)
				)
				.onTapGesture(count: 2) {
					imageZoom = 1
					imageOffset = .zero
				}
				// Outside the card, in the preview's own top-leading corner.
				//
				// It began inside the card's metadata block, mirroring the QR badge, and that was the
				// mistake: the card is drawn through `scaleEffect`, so everything on it — including a
				// 44pt button — comes out at the preview's fit scale, which is about a third on iPad.
				// The result was a target a few points across (reported from a build). Out here it is
				// a sibling of the scaled card rather than part of it, so it is exactly the size it
				// says it is, at every card size and both orientations.
				.overlay(alignment: .topLeading) { enlargeButton }
		}
	}

	/// How much height the card preview claims before the controls get any.
	///
	/// Three cases, because the space differs by an order of magnitude: a sheet the system sizes for
	/// us (iPad, Mac), a phone in portrait, and a phone on its side — where the whole sheet is
	/// shorter than the controls alone.
	private var previewFloor: CGFloat {
		if SheetRoom.isGenerous { return 400 }
		return verticalSizeClass == .compact ? 150 : 220
	}

	/// The controls, which scroll so that the preview's floor is always honoured.
	///
	/// Scrolling everywhere, not only where the sheet is roomy. The first version left the phone
	/// alone on the grounds that it had no room to redistribute — but that is exactly the case that
	/// broke: in landscape the controls are taller than the sheet, so without somewhere to scroll
	/// they took the preview's space and the card vanished.
	private var controlsArea: some View {
		ScrollView { controls }
	}

	private var controls: some View {
		VStack(spacing: 16) {
			HStack(spacing: 12) {
				Image(systemName: "plus.magnifyingglass")
					.foregroundStyle(.secondary)
				Slider(value: $imageZoom, in: Self.zoomRange)
					.testability(Testability.Slider.findingShareZoom)
			}

			Picker(L10n.Finding.Share.theme, selection: $theme) {
				Text(L10n.Finding.Share.light).tag(ColorScheme.light)
				Text(L10n.Finding.Share.dark).tag(ColorScheme.dark)
			}
			.pickerStyle(.segmented)
			.testability(Testability.Picker.findingShareTheme)

			Picker(L10n.Finding.Share.layout, selection: $orientation) {
				Text(L10n.Finding.Share.portrait).tag(ShareCardOrientation.portrait)
				Text(L10n.Finding.Share.landscape).tag(ShareCardOrientation.landscape)
			}
			.pickerStyle(.segmented)
			.testability(Testability.Picker.findingShareLayout)

			// Offered only when there is something to withhold. On a finding with no coordinate the
			// control would be a switch over nothing — and worse than useless, since its presence
			// would suggest a location was recorded.
			if subject.gps != nil {
				VStack(alignment: .leading, spacing: 6) {
					Toggle(L10n.Finding.Share.includeLocation, isOn: $includesLocation)
						.testability(Testability.Toggle.findingShareIncludeLocation)
					Text(L10n.Finding.Share.includeLocationFootnote)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
			}

			// Labelled by its consequence, not its mechanism: nothing on screen tells the user what
			// "include a link" would change, and the trade-off it makes is invisible until the system
			// sheet is already up and Save Image is missing from it. Hidden entirely when the feature
			// is off, so a dark flag leaves the composer exactly as it was.
			if isLinkEnabled {
				VStack(alignment: .leading, spacing: 6) {
					Toggle(L10n.Finding.Share.includeLink, isOn: $includesLink)
						.testability(Testability.Toggle.findingShareIncludeLink)
					Text(L10n.Finding.Share.includeLinkFootnote)
						.font(.footnote)
						.foregroundStyle(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)

					if includesLink, subject.page != nil {
						addressChoice
					}
				}
			}
		}
		// Re-clamp when zooming out via the slider; reset framing per orientation.
		.onChange(of: imageZoom) { _, newZoom in
			imageOffset = clampedOffset(imageOffset, zoom: newZoom)
		}
		.onChange(of: orientation) { _, _ in
			imageZoom = 1
			imageOffset = .zero
		}
	}

	private func clampZoom(_ value: CGFloat) -> CGFloat {
		min(max(Self.zoomRange.lowerBound, value), Self.zoomRange.upperBound)
	}

	/// Clamps the pan so the cover-filled, zoomed image never reveals an edge.
	private func clampedOffset(_ raw: CGSize, zoom: CGFloat) -> CGSize {
		guard let image = subject.image else { return .zero }
		let slot = orientation.imageSlotSize
		let cover = slot.coverSize(for: image.size)
		let maxX = max(0, (cover.width * zoom - slot.width) / 2)
		let maxY = max(0, (cover.height * zoom - slot.height) / 2)
		return CGSize(
			width: min(max(-maxX, raw.width), maxX),
			height: min(max(-maxY, raw.height), maxY)
		)
	}

	private func share() {
		let card = FindingShareCard(
			subject: publishedSubject,
			orientation: orientation,
			zoom: clampZoom(imageZoom),
			offset: clampedOffset(imageOffset, zoom: clampZoom(imageZoom)),
			link: cardLink
		)
		.environment(\.colorScheme, theme)
		// Render at ≥3x for a crisp, social-ready PNG regardless of device scale.
		DefaultRenderer().render(card, scale: max(displayScale, 3)) { image, _ in
			guard let image else {
				LoggingPolicy.warning("Share card render failed; nothing to share", logger: .storage)
				return
			}
			// A link CAN ride along, and since AIA-0650 it does — but only as a `String`, never as a
			// `URL`. A `URL` item would make LinkPresentation fetch that address from this device to
			// build the sheet's header, an unasked-for network request behind a purely local action,
			// and would switch the sheet to link-preview presentation, hiding the image. The honest
			// cost of attaching it at all — Save Image and image-only extensions leave the sheet,
			// because an activity must accept every item — is what the toggle above gives back.
			// `FindingShareActivity.items` carries the full reasoning, including why a
			// `UIActivityItemSource` cannot dodge any of it.
			sharePayload = ActivitySharePayload(
				items: FindingShareActivity.items(
					image: image,
					subject: publishedSubject,
					isLinkEnabled: isLinkEnabled,
					includesLink: includesLink,
					pageDetail: pageDetail
				)
			)
		}
	}
}

extension Bundle {
	/// The app's display name (`PRODUCT_NAME` → `CFBundleDisplayName`/`CFBundleName`),
	/// so the brand is sourced from one place and follows any rename.
	var appName: String {
		(object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
			?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
			?? "ML Browser"
	}

	/// The app's own icon, resolved from the compiled `CFBundleIcons` entry.
	/// `UIImage(named: "AppIcon")` does not reliably return the asset-catalog app
	/// icon, so the icon filename is read from the bundle instead.
	var appIcon: UIImage? {
		guard
			let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
			let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
			let files = primary["CFBundleIconFiles"] as? [String],
			let lastIcon = files.last
		else { return nil }
		return UIImage(named: lastIcon)
	}
}

/// The coordinate on the share card.
///
/// A view of its own for one reason: it is the row with a rule — **if a coordinate is on the card
/// it is on the card whole** — and a rule that lives inline in a `VStack` can only be tested by a
/// copy of itself, which passes whatever the card actually does.
///
/// **No line cap at all.** A recorded coordinate can carry its coordinate system and a projected
/// pair runs long: `Web Mercator (EPSG:3857): 1134425.9924799, 6045439.9357442` is 57 characters,
/// against a text column only about 170pt wide in the worst case — the landscape metadata block
/// less its padding, the spacing, and the widest QR badge the card can draw. Two lines with a scale
/// factor was the previous rule and it still cut that string (reported from a build), because a cap
/// is a guess about a length nobody controls. What truncation removes is the DIGITS, leaving a
/// reader who knows what kind of coordinate it is and not where.
///
/// `fixedSize` vertically is what makes it binding: it makes this row inflexible, so the stack must
/// grant the height the text needs and takes it from the note above, the only flexible row here and
/// the one that can afford it.
struct FindingShareCoordinateRow: View {
	let gps: String

	/// The narrowest the card's text column can ever be, and therefore the width any claim about
	/// this row has to be tested at: the landscape metadata block, less 16pt of padding on each
	/// side, the 12pt gap before the badge, and the widest badge the card can draw.
	static let narrowestTextColumn: CGFloat = {
		let block = ShareCardOrientation.landscape.size.width
			- ShareCardOrientation.landscape.imageSlotSize.width
		return block - 32 - 12 - FindingShareLinkBadge.maximumWidth
	}()

	var body: some View {
		Label(gps, systemImage: "location")
			.font(.caption)
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)
	}
}
