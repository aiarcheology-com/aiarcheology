//
//  FindingsListView.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers

/// The findings inventory (AIA-0215): stored detections with label filtering,
/// presented as a sheet from the drawer's Findings section.
struct FindingsListView: View {
	@Environment(\.dismiss) private var dismiss
	@Environment(\.managedObjectContext) private var moc
	/// Held only to hand on to the share composer's own sheet, which needs it live (AIA-0650).
	@EnvironmentObject private var featureFlags: FeatureFlagsState

	/// The persist/restore transaction. Passed by initializer rather than injected as an environment
	/// object because `FindingRepository` is a plain type (AIA-0303) — the same way `DrawerContent`
	/// hands it to `SettingsForm` and `WebScreen` to `SaveFindingSheet`.
	///
	/// Declared BEFORE `onOpenPage` so the memberwise initializer ends on the closure and the call
	/// site keeps its trailing-closure form.
	let findingRepository: FindingRepository

	/// Cloud sync, when the build has it. Declared BEFORE `onOpenPage` for the same reason
	/// `findingRepository` is: the memberwise initializer must end on the closure.
	@ObservedObject var findingsSync: FindingsSyncCoordinator

	/// Read for one bit -- whether anyone is signed in -- and to present the sign-in sheet the
	/// back-up button raises when nobody is (AIA-740). Declared BEFORE `onOpenPage`, same reason.
	@ObservedObject var authState: AuthState

	/// "Open page" routes through the presenting drawer: it must dismiss this
	/// sheet and the drawer before the web screen loads the URL.
	let onOpenPage: (URL) -> Void

	@FetchRequest(
		sortDescriptors: [NSSortDescriptor(keyPath: \Finding.creationDate_, ascending: false)],
		predicate: NSPredicate(
			format: "%K == %@",
			#keyPath(Finding.lifeCycleString),
			CoreDataManageableState.ready.rawValue
		),
		animation: .default)
	private var findings: FetchedResults<Finding>

	/// nil = no filter (all findings, including unlabeled ones).
	@State private var filterLabel: String?

	// MARK: Ordering (AIA-0748)

	/// Order and direction are held as two pieces of state, not one six-case enum: they are
	/// independent behavioural dimensions, and collapsing them would make illegal states no fewer
	/// while making "keep the order, flip the direction" unexpressible without a lookup table.
	///
	/// Deliberately not persisted -- the choice resets to newest-first each time the sheet opens,
	/// exactly as the address dialog's own sort control does.
	@State private var sortOrder: SortOrder = .date
	@State private var isReversed = false

	/// ZIP export goes straight to the system share sheet; per-finding sharing
	/// goes through the composer (which owns its own share-sheet presentation).
	@State private var sharePayload: ActivitySharePayload?
	@State private var shareSubject: FindingShareSubject?
	@State private var isExporting = false
	@State private var exportFailed = false

	// MARK: Import (AIA-713)

	@State private var isPresentingImporter = false
	@State private var isImporting = false
	@State private var importFailed = false
	/// A decoded archive waiting on the user's skip-or-replace answer. Holding the decoded contents
	/// — rather than the file URL — means answering the question does not re-read or re-inflate it.
	@State private var pendingImport: FindingArchiveContents?
	@State private var pendingDuplicateCount = 0
	@State private var importSummary: FindingRepository.ImportSummary?

	// MARK: Back up (AIA-740)

	@State private var showSignIn = false
	/// Set only when the sign-in sheet was raised *by the back-up button*, so a sign-in the user
	/// started from somewhere else never triggers an upload they did not ask for.
	@State private var signInWasForBackUp = false

	/// Real Clerk-backed auth vs. the DEBUG mock. Re-injected across the sign-in sheet boundary
	/// below, where `SignInSheet` branches on it -- losing it there traps rather than degrades.
	@Environment(\.usesRealAuth) private var usesRealAuth

	var body: some View {
		// Ordered ONCE per body pass and threaded to every reader: `filteredFindings` is a computed
		// property, so the empty check, the ForEach and the export button would otherwise each
		// re-run the whole sort. This array must never outlive the body pass -- see
		// `dataMenu(isExportDisabled:)`, which takes a Bool rather than the findings for that reason.
		let items = Self.ordered(filteredFindings, by: sortOrder, reversed: isReversed)
		return NavigationStack {
			VStack(spacing: 0) {
				syncStatus
				if distinctLabels.isEmpty.not {
					filterChips
				}
				List {
					if items.isEmpty {
						emptyStateView
					}
					ForEach(items, id: \.objectID) { finding in
						row(finding)
					}
				}
				.listStyle(.plain)
			}
			.safeAreaInset(edge: .bottom) {
				// Hidden outright when this build has no Worker to talk to: `backUpNow` returns
				// without doing anything there, and a green button that does nothing is worse than
				// no button.
				if findingsSync.isCloudConfigured { backUpBar }
			}
			.navigationTitle(L10n.Findings.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItemGroup(placement: .navigationBarLeading) {
					dataMenu(isExportDisabled: items.isEmpty)
					sortMenu
				}
				ToolbarItem(placement: .navigationBarTrailing) {
					Button(action: { dismiss() }) {
						Text(L10n.Common.dismiss)
					}
					.tint(.blue)
					.testability(Testability.Button.findingsDismiss)
				}
			}
			.navigationDestination(for: Finding.self) { finding in
				FindingDetailView(
					finding: finding,
					findingRepository: findingRepository,
					onOpenPage: onOpenPage
				)
			}
		}
		.onAppear {
			// Self-heal write-time leftovers (image written, entity insert failed) and
			// failed file deletes. Runs on the viewContext/MainActor; the save sheet
			// is dismissed before this list can open, so it never races a save.
			FindingScreenshotStore.sweepOrphans(in: moc)
		}
		// Driven by the account appearing, NOT by the sheet closing. `SignInSheet` validates the
		// session asynchronously after Clerk's own sheet goes away, so at dismissal the identifier
		// can still be nil for a session that is about to succeed -- reading it there dropped the
		// user's intent and left the old exclusion in place for ever.
		//
		// Dismissing without signing in still uploads nothing: no account ever appears. The flag
		// lives only as long as this sheet, and the button is the only way to raise a sign-in from
		// here, so it cannot be spent on an unrelated one.
		.onChange(of: authState.accountIdentifier) { _, account in
			guard signInWasForBackUp, let account else { return }
			signInWasForBackUp = false
			findingsSync.backUpNow(expectedAccount: account)
		}
		.sheet(isPresented: $showSignIn, onDismiss: {
			// The sheet closes itself only once `refresh()` has succeeded, so anything else is an
			// abandoned sign-in and the intent goes with it. Left standing, the flag outlived the
			// sheet and a much later session validation -- a foreground after a cold offline
			// launch, say -- would fire a full back-up that lifts every "Keep on This Device" the
			// user had recorded. Erring towards forgetting is the safe direction: the button is
			// right there.
			if authState.gate != .ready { signInWasForBackUp = false }
		}) {
			SignInSheet(authState: authState)
				// Custom environment values do not reliably cross a sheet boundary on Mac
				// (Designed for iPad) — AGENTS.md §3, same as the drawer's own sign-in sheet.
				.environment(\.usesRealAuth, usesRealAuth)
		}
		.activityShareSheet($sharePayload)
		.sheet(item: $shareSubject) { subject in
			FindingShareComposer(subject: subject)
				// Environment objects do not reliably cross a `.sheet` boundary on Mac (Designed for
				// iPad) — re-inject, per AGENTS.md §3.
				.environmentObject(featureFlags)
		}
		.alert(L10n.Findings.Export.error, isPresented: $exportFailed) {
			Button(L10n.Common.ok, role: .cancel) {}
		}
		.fileImporter(
			isPresented: $isPresentingImporter,
			allowedContentTypes: [.zip],
			allowsMultipleSelection: false
		) { result in
			switch result {
			case let .success(urls):
				if let url = urls.first { Task { await decodeArchive(at: url) } }
			case let .failure(error):
				LoggingPolicy.warning("Findings import cancelled or failed: \(error.localizedDescription)", logger: .storage)
			}
		}
		.alert(L10n.Findings.Import.error, isPresented: $importFailed) {
			Button(L10n.Common.ok, role: .cancel) {}
		}
		// Asked ONCE, with a real count, instead of per finding: importing must never silently
		// create a second copy of a finding the device already has, and must never silently
		// overwrite one either.
		.alert(
			L10n.Findings.Import.Duplicates.title,
			isPresented: Binding(get: { pendingImport != nil }, set: { if $0 == false { pendingImport = nil } })
		) {
			Button(L10n.Findings.Import.Duplicates.keep) { commitPendingImport(duplicates: .skip) }
			Button(L10n.Findings.Import.Duplicates.replace, role: .destructive) { commitPendingImport(duplicates: .replace) }
			Button(L10n.Common.cancel, role: .cancel) { pendingImport = nil }
		} message: {
			Text(L10n.Findings.Import.Duplicates.message(pendingDuplicateCount))
		}
		.alert(
			L10n.Findings.Import.Result.title,
			isPresented: Binding(get: { importSummary != nil }, set: { if $0 == false { importSummary = nil } })
		) {
			Button(L10n.Common.ok, role: .cancel) { importSummary = nil }
		} message: {
			let summary = importSummary ?? .init()
			Text(L10n.Findings.Import.Result.message(summary.restored, summary.skipped, summary.failed))
		}
	}

	// MARK: - Import

	/// Reads and validates the archive off the MainActor, then decides whether a question is needed.
	///
	/// The picked file lives outside the sandbox, so it is opened under a security scope and copied
	/// into the app's own temporary directory FIRST: the scope must be released promptly, and the
	/// decode that follows is asynchronous.
	private func decodeArchive(at url: URL) async {
		isImporting = true
		let staged = FileManager.default.temporaryDirectory
			.appendingPathComponent("findings-import-\(UUID().uuidString).zip")
		do {
			// Copying a multi-hundred-megabyte archive is real IO and does not belong on the main
			// thread. The security scope is opened and closed around the copy inside the same
			// detached task, so it is held for exactly as long as the read needs it.
			try await Task.detached(priority: .userInitiated) {
				let scoped = url.startAccessingSecurityScopedResource()
				defer { if scoped { url.stopAccessingSecurityScopedResource() } }
				try FileManager.default.copyItem(at: url, to: staged)
			}.value
		} catch {
			LoggingPolicy.error("Could not stage the picked findings archive", error: error, logger: .storage)
			isImporting = false
			importFailed = true
			return
		}

		Task {
			defer { try? FileManager.default.removeItem(at: staged) }
			do {
				// Unzip, JSON parsing and image inspection all run off the MainActor: this view's
				// context is the viewContext, and a 200-finding archive would otherwise block it.
				let contents = try await Task.detached(priority: .userInitiated) {
					try FindingArchiveImport.read(archiveAt: staged)
				}.value

				let duplicates = findingRepository.duplicateCount(in: contents)
				if duplicates > 0 {
					pendingDuplicateCount = duplicates
					pendingImport = contents
				} else {
					apply(contents, duplicates: .skip)
				}
			} catch {
				LoggingPolicy.error("Could not read the findings archive", error: error, logger: .storage)
				importFailed = true
			}
			isImporting = false
		}
	}

	private func commitPendingImport(duplicates: FindingRepository.DuplicatePolicy) {
		guard let contents = pendingImport else { return }
		pendingImport = nil
		// Deferred by one turn: setting `importSummary` synchronously here would raise the result
		// alert while the duplicates alert is still dismissing, and SwiftUI drops the second — the
		// user would replace their findings and be told nothing at all.
		Task { @MainActor in
			apply(contents, duplicates: duplicates)
		}
	}

	private func apply(_ contents: FindingArchiveContents, duplicates: FindingRepository.DuplicatePolicy) {
		do {
			importSummary = try findingRepository.importFindings(contents, duplicates: duplicates)
		} catch {
			LoggingPolicy.error("Failed to import findings", error: error, logger: .storage)
			importFailed = true
		}
	}

	// MARK: - Export & share

	/// Export and import, behind one toolbar button (AIA-0748).
	///
	/// They were two separate text buttons until the sort control joined them: three items beside
	/// an inline navigation title crowded the bar at larger Dynamic Type sizes. Grouping the two
	/// archive actions under one noun leaves the leading group with two controls -- data, and order.
	///
	/// Export takes the emptiness as a `Bool` rather than the ordered array on purpose: the array is
	/// render-time state, and this action closure runs later. Capturing managed objects here would
	/// let a cloud tombstone (`FindingsSyncCoordinator` applies deletes while this sheet is open)
	/// delete a row between render and tap -- and reading an attribute off a deleted, saved object
	/// traps on a fault it cannot fulfil rather than returning nil.
	///
	/// The whole menu collapses to a spinner while either job runs: both write the same archive
	/// surface, and offering the other action mid-job would invite exactly the overlap neither
	/// path is written to survive.
	@ViewBuilder
	private func dataMenu(isExportDisabled: Bool) -> some View {
		if isExporting || isImporting {
			ProgressView()
		} else {
			Menu {
				Button(action: exportFindings) {
					Label(L10n.Findings.export, systemImage: "square.and.arrow.up")
				}
				.disabled(isExportDisabled)
				.testability(Testability.Button.findingsExport)

				Button(action: { isPresentingImporter = true }) {
					Label(L10n.Findings.import, systemImage: "square.and.arrow.down")
				}
				.testability(Testability.Button.findingsImport)
			} label: {
				Text(L10n.Findings.data)
			}
			.tint(.blue)
			.testability(Testability.Button.findingsDataMenu)
		}
	}

	private func exportFindings() {
		// Re-derived here, at tap time, rather than captured from the body pass -- see
		// `exportButton(isDisabled:)`. One sort on a user action costs nothing.
		let snapshots = Self.ordered(filteredFindings, by: sortOrder, reversed: isReversed)
			.map(FindingSnapshot.init)
		isExporting = true
		Task {
			do {
				let url = try await Task.detached(priority: .userInitiated) {
					try FindingExporter.makeZip(from: snapshots)
				}.value
				sharePayload = ActivitySharePayload(items: [url])
			} catch {
				LoggingPolicy.error("Failed to export findings", error: error, logger: .storage)
				exportFailed = true
			}
			isExporting = false
		}
	}

	private func share(_ finding: Finding) {
		shareSubject = FindingShareSubject(finding)
	}

	// MARK: - Filtering

	private var distinctLabels: [String] {
		Finding.distinctLabels(in: moc)
	}

	private var filteredFindings: [Finding] {
		guard let filterLabel else { return Array(findings) }
		// Case-insensitive, matching the chips' identity (distinctLabels).
		return findings.filter { $0.label_?.caseInsensitiveCompare(filterLabel) == .orderedSame }
	}

	private var filterChips: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				chip(title: L10n.Findings.Filter.all, isSelected: filterLabel.isNil) {
					filterLabel = nil
				}
				ForEach(distinctLabels, id: \.self) { label in
					chip(title: label, isSelected: filterLabel == label) {
						filterLabel = label
					}
				}
			}
			.padding(.horizontal)
			.padding(.vertical, 8)
		}
	}

	// MARK: - Ordering control (AIA-0748)

	/// Shaped like `LocationSheetView.sortMenu` -- one toolbar button opening a `Menu` -- with a
	/// reverse item added, so three orders cover six results without a second toolbar button.
	///
	/// Reverse is a `Button` with a direction-encoding symbol, **not** a `Toggle`: no `Menu` in this
	/// app contains one, and this sheet also ships to iOS-on-Mac, where menu items render through a
	/// different path. `CatalogBrowseView`'s provider menu is the shipping precedent for a
	/// state-encoding button inside a menu.
	private var sortMenu: some View {
		Menu {
			orderItem(.date, title: L10n.Findings.Sort.date, systemImage: "clock",
			          id: Testability.Button.findingsSortByDate)
			orderItem(.alphabetical, title: L10n.Findings.Sort.alphabetical, systemImage: "textformat.abc",
			          id: Testability.Button.findingsSortByTitle)
			orderItem(.host, title: L10n.Findings.Sort.host, systemImage: "globe",
			          id: Testability.Button.findingsSortByHost)
			Button {
				withAnimation { isReversed.toggle() }
			} label: {
				Label(L10n.Findings.Sort.reverse, systemImage: isReversed ? "arrow.up" : "arrow.down")
			}
			// A button carrying its state in a symbol is visually stateful but audibly stateless:
			// the symbol is decorative to VoiceOver, so without this trait "Reverse" would be
			// announced identically in both directions. `.isSelected` is how the picker's own
			// chosen row already announces.
			.accessibilityAddTraits(isReversed ? .isSelected : [])
			.testability(Testability.Button.findingsSortReverse)
		} label: {
			Image(systemName: "arrow.up.arrow.down")
		}
		.accessibilityLabel(L10n.Findings.Sort.label)
		// The active order only -- never the order and the direction concatenated at runtime.
		// Assembled sentences break word order and right-to-left layout across the locales; the
		// direction is announced by the reverse button's `.isSelected` trait instead.
		.accessibilityValue(sortOrderName)
		.testability(Testability.Button.findingsSortOrder)
	}

	/// One order row.
	///
	/// Buttons rather than a `Picker`: each row needs its own accessibility identifier so a UI test
	/// can address it directly instead of matching translated text, and a `Picker`'s rows do not
	/// carry one through. Selection is drawn and announced the way `CatalogBrowseView`'s provider
	/// menu does it -- a checkmark plus the `.isSelected` trait -- so nothing is lost by not using
	/// a `Picker`.
	private func orderItem(
		_ order: SortOrder,
		title: String,
		systemImage: String,
		id: Testability.Button
	) -> some View {
		let isActive = sortOrder == order
		return Button {
			withAnimation { sortOrder = order }
		} label: {
			Label(title, systemImage: isActive ? "checkmark" : systemImage)
		}
		.accessibilityAddTraits(isActive ? .isSelected : [])
		.testability(id)
	}

	private var sortOrderName: String {
		switch sortOrder {
		case .date: return L10n.Findings.Sort.date
		case .alphabetical: return L10n.Findings.Sort.alphabetical
		case .host: return L10n.Findings.Sort.host
		}
	}

	private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			Text(title)
				.font(.callout)
				.padding(.horizontal, 12)
				.padding(.vertical, 5)
				.background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
				.foregroundStyle(isSelected ? .white : .primary)
		}
		.buttonStyle(.borderless)
		.testability(Testability.Button.findingsFilterLabel, label: title)
	}

	// MARK: - Rows

	private func row(_ finding: Finding) -> some View {
		NavigationLink(value: finding) {
			HStack(spacing: 12) {
				thumbnail(finding)
				VStack(alignment: .leading, spacing: 2) {
					Text(finding.displayTitle)
						.foregroundStyle(.primary)
					if let page = finding.page, let host = page.host {
						Text(host)
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					if let date = finding.creationDate_ {
						Text(date, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
			}
		}
		.testability(Testability.Button.findingsItem)
		.swipeActions(edge: .trailing, allowsFullSwipe: true) {
			Button(role: .destructive) {
				delete(finding)
			} label: {
				Label(L10n.Common.delete, systemImage: "trash")
			}
			.testability(Testability.Button.findingsDeleteEntry)
		}
		.swipeActions(edge: .leading) {
			Button {
				share(finding)
			} label: {
				Label(L10n.Common.share, systemImage: "square.and.arrow.up")
			}
			.tint(.blue)
			.testability(Testability.Button.findingsShareEntry)
		}
		// Right-click is the Mac idiom, and on a Mac it is the ONLY way to reach these
		// actions: a pointer cannot swipe a row. So the menu mirrors BOTH swipe
		// actions, destructive one last. It stays Mac-only because on touch the swipes
		// are already the affordances (AIA-0659).
		.macContextMenu {
			Button {
				share(finding)
			} label: {
				Label(L10n.Common.share, systemImage: "square.and.arrow.up")
			}
			Button(role: .destructive) {
				delete(finding)
			} label: {
				Label(L10n.Common.delete, systemImage: "trash")
			}
			.testability(Testability.Button.findingsDeleteEntry)
		}
	}

	@ViewBuilder
	private func thumbnail(_ finding: Finding) -> some View {
		if let image = finding.cropThumbnail() {
			Image(uiImage: image)
				.resizable()
				.scaledToFill()
				.frame(width: 56, height: 56)
				.clipShape(RoundedRectangle(cornerRadius: 8))
		} else {
			// Row whose file is missing: placeholder, never auto-deleted (the
			// orphan sweep only removes files WITHOUT rows).
			Image(systemName: "photo")
				.foregroundStyle(.secondary)
				.frame(width: 56, height: 56)
				.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
		}
	}

	private var emptyStateView: some View {
		VStack(spacing: 12) {
			Image(systemName: "archivebox")
				.font(.largeTitle)
				.foregroundStyle(.secondary)
			Text(L10n.Findings.Empty.title)
				.font(.headline)
			Text(L10n.Findings.Empty.message)
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 32)
	}

	// MARK: - Back up (AIA-740)

	/// Pinned to the bottom of the sheet as a `safeAreaInset`, so the list scrolls *under* it and
	/// the last finding is never hidden behind it.
	///
	/// Deliberately not a row in the list. A long list is exactly the situation in which someone
	/// wants this, and a row would have scrolled out of reach by then.
	private var backUpBar: some View {
		VStack(spacing: 8) {
			if let outcome = findingsSync.lastManualBackup {
				label(backUpMessage(for: outcome), icon: backUpIcon(for: outcome), tint: backUpTint(for: outcome))
			}
			Button {
				if let account = authState.accountIdentifier {
					// The account the user is looking at travels with the request; the coordinator
					// refuses it if the provider has moved on.
					findingsSync.backUpNow(expectedAccount: account)
				} else if let account = findingsSync.syncingAccount {
					// Signed in as far as sync is concerned, but `AuthState` has not caught up --
					// a cold launch with no signal is the ordinary case. Offering a sign-in that
					// cannot complete offline, for an account already signed in, was the wrong
					// answer; asking for the back-up gets the honest "you are offline" instead.
					findingsSync.backUpNow(expectedAccount: account)
				} else {
					// Signing in is what makes a back-up possible, so the button opens that door rather
					// than doing nothing. Nothing uploads unless the sign-in actually succeeds.
					signInWasForBackUp = true
					showSignIn = true
				}
			} label: {
				HStack(spacing: 8) {
					if findingsSync.isBackingUp {
						ProgressView().controlSize(.small).tint(.white)
					}
					Text(findingsSync.isBackingUp ? L10n.Findings.Sync.Backup.busy : L10n.Findings.Sync.Backup.button)
				}
				// Sized to its label rather than edge to edge: full-bleed made it read as a
				// modal's primary action rather than one control on a list of findings.
				.padding(.horizontal, 12)
			}
			.buttonStyle(.borderedProminent)
			.controlSize(.regular)
			// Green means "this will work". A full account is the one state where it will not, so
			// the button stops claiming otherwise -- but stays ENABLED, because deleting a finding
			// frees room and the retry has to be available the moment it does.
			.tint(findingsSync.isQuotaBlocked ? .gray : .green)
			.disabled(findingsSync.isBackingUp)
			.testability(Testability.Button.findingsBackUp)
		}
		.padding(.horizontal)
		.padding(.vertical, 14)
		// Spans leading to trailing so the bar reads as a footer for the list. Without it the
		// VStack hugs the button and `.bar` paints a floating box around it.
		.frame(maxWidth: .infinity)
		.background(.bar)
	}

	private func backUpMessage(for outcome: FindingsSyncCoordinator.ManualBackupOutcome) -> String {
		switch outcome {
		case .succeeded: return L10n.Findings.Sync.Backup.succeeded
		case .offline: return L10n.Findings.Sync.Backup.offline
		// Reuses the storage-full wording the header already shows: it names the way out --
		// remove findings or export them -- which is the only thing that helps here.
		case .quotaFull: return L10n.Findings.Sync.Storage.full
		case .failed: return L10n.Findings.Sync.Backup.failed
		}
	}

	private func backUpIcon(for outcome: FindingsSyncCoordinator.ManualBackupOutcome) -> String {
		switch outcome {
		case .succeeded: return "checkmark.icloud"
		case .offline: return "icloud.slash"
		case .quotaFull: return "externaldrive.fill.badge.xmark"
		case .failed: return "exclamationmark.icloud"
		}
	}

	private func backUpTint(for outcome: FindingsSyncCoordinator.ManualBackupOutcome) -> Color {
		switch outcome {
		case .succeeded: return .green
		case .offline: return .secondary
		case .quotaFull: return .red
		case .failed: return .orange
		}
	}

	/// What sync owes, and what it needs from the user.
	///
	/// Deliberately quiet: the common state is nothing to say. A count appears only when findings
	/// are actually waiting, and the storage band only once the account is most of the way full,
	/// because a permanent banner about a working feature is noise the user learns to ignore.
	@ViewBuilder
	private var syncStatus: some View {
		let usage = findingsSync.usage
		let fraction = usage?.fraction ?? 0
		// `.subheadline` rather than `.footnote` (AIA-0757): one step up, still clearly secondary to
		// the rows, but no longer the smallest text on the sheet — which is what made a status line
		// read as a disclaimer.
		let statusFont = Font.subheadline
		VStack(alignment: .leading, spacing: 4) {
			if findingsSync.pendingUploadCount > 0 {
				label(L10n.Findings.Sync.pending(findingsSync.pendingUploadCount), icon: "arrow.up.circle", tint: .secondary, font: statusFont)
			}
			if findingsSync.parkedCount > 0 {
				label(L10n.Findings.Sync.parked(findingsSync.parkedCount), icon: "exclamationmark.circle", tint: .orange, font: statusFont)
			}
			if fraction >= 1 || findingsSync.isQuotaBlocked {
				// Says what to do, not merely that something is wrong. Exporting keeps working at
				// 100% on purpose — it is both a data-portability right and the only way out of a
				// full account.
				//
				// `isQuotaBlocked` and not the fraction alone (AIA-0748 production pass): an account
				// can be refusing every upload while the fraction still reads 97%, because what is
				// left will not fit a finding. Showing a percentage there invites "so why did it
				// refuse?", and the coordinator already draws this distinction for the back-up
				// button — a fraction near 1 is not the same claim as the server refusing a write.
				label(L10n.Findings.Sync.Storage.full, icon: "externaldrive.fill.badge.xmark", tint: .red, font: statusFont)
			} else if fraction >= 0.8 {
				label(L10n.Findings.Sync.Storage.warning(Int(fraction * 100)), icon: "externaldrive.fill", tint: .orange, font: statusFont)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal)
		.padding(.vertical, findingsSync.pendingUploadCount > 0 || fraction >= 0.8 || findingsSync.isQuotaBlocked ? 8 : 0)
	}

	/// Shared by the aggregate sync lines above the list **and** the manual back-up outcome in the
	/// pinned bar below it, which is why the size is a parameter rather than a constant: AIA-0757
	/// raises only the aggregate line (it was the smallest text on the sheet and read as a
	/// disclaimer rather than status). The manual outcome keeps `.footnote` — it is transient
	/// feedback attached to a button the user just pressed, not standing status.
	private func label(_ text: String, icon: String, tint: Color, font: Font = .footnote) -> some View {
		Label(text, systemImage: icon)
			.font(font)
			.foregroundStyle(tint)
	}

	/// Deleting goes through the repository so the tombstone reaches the cloud (AIA-727). Doing it
	/// inline here would delete the finding on this device and leave every other device holding it.
	private func delete(_ finding: Finding) {
		do {
			try findingRepository.delete(finding)
		} catch {
			LoggingPolicy.error("Failed to delete the finding", error: error, logger: .storage)
		}
	}
}

// MARK: - Ordering (AIA-0748)

extension FindingsListView {

	/// Which key the findings list is ordered by. Direction is held separately (`isReversed`).
	enum SortOrder: Hashable {
		case date
		case alphabetical
		case host
	}

	/// One finding with its sort key already extracted.
	///
	/// A `struct` rather than a tuple deliberately: with the `id` terminator this carries four
	/// members, and SwiftLint's `large_tuple` warns at four.
	private struct Decorated {
		/// nil means this finding has **no key** for the active order and belongs in the trailing
		/// group. An empty string is never a key -- see `sortKey(for:order:)`.
		let key: String?
		let date: Date?
		/// The terminator that makes every comparison chain total. `entityId` is non-optional.
		let id: String
		let finding: Finding
	}

	/// The findings in display order.
	///
	/// The rule in one sentence: **partition into keyed and key-less, reverse the keyed slice only,
	/// and always leave the key-less group last.** Reversing a sort should not promote the least
	/// informative rows to the top, so a finding with no host -- or no date, or no title text --
	/// stays at the bottom in *both* directions. That is the P0 decision, applied to all three
	/// orders rather than to `host` alone.
	///
	/// Pure and `static` so the rule, which is the part carrying the edge cases, is testable
	/// without standing up a view. **Internal, not `private`:** a `private static` is unreachable
	/// from `@testable import`, which would leave this untested while looking tested.
	///
	/// Decorate-sort-undecorate, so each key is extracted once (O(n)) instead of on every
	/// comparison. Note what that does *not* buy: `localizedStandardCompare` is an ICU call that
	/// still runs per comparison and dominates at scale. A folded precomputed sort key is the next
	/// lever and is deliberately out of scope -- findings are hand-captured, so the assumed
	/// magnitude here is hundreds, not thousands.
	static func ordered(_ findings: [Finding], by order: SortOrder, reversed: Bool) -> [Finding] {
		var keyed: [Decorated] = []
		var keyless: [Decorated] = []

		for finding in findings {
			let element = Decorated(
				key: sortKey(for: finding, order: order),
				date: finding.creationDate_,
				id: finding.entityId.uuidString,
				finding: finding
			)
			// The date order keys off the date; the other two key off their string.
			let isKeyed = order == .date ? element.date != nil : element.key != nil
			if isKeyed {
				keyed.append(element)
			} else {
				keyless.append(element)
			}
		}

		keyed.sort { compare($0, $1, order: order) }
		// Fixed newest-first order, and never reversed: this group is what reversing must not
		// promote. Reversing only the keyed slice also makes reverse an involution on it.
		keyless.sort { byDateThenID($0, $1) }

		let directed = reversed ? Array(keyed.reversed()) : keyed
		return (directed + keyless).map(\.finding)
	}

	/// nil = no key for this order, i.e. the trailing group.
	private static func sortKey(for finding: Finding, order: SortOrder) -> String? {
		switch order {
		case .date:
			// No string key participates; keyed-ness comes from `creationDate_`.
			return nil
		case .alphabetical:
			// `displayTitle` is non-optional but not non-empty: the import path assigns `label_`
			// raw while only the save path normalises empty to nil, and `??` tests nil rather than
			// emptiness. An imported row can therefore render as "" -- which would otherwise sort
			// to the very top as a blank leading row.
			let title = finding.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
			return title.isEmpty ? nil : title
		case .host:
			guard let host = finding.page?.host, host.isEmpty.not else { return nil }
			return host
		}
	}

	private static func compare(_ lhs: Decorated, _ rhs: Decorated, order: SortOrder) -> Bool {
		switch order {
		case .date:
			return byDateThenID(lhs, rhs)
		case .alphabetical, .host:
			// Both keys are non-nil here -- key-less elements were partitioned out. The empty
			// fallbacks keep this total without forcing an optional the partition already excluded.
			let comparison = (lhs.key ?? "").localizedStandardCompare(rhs.key ?? "")
			if comparison != .orderedSame {
				return comparison == .orderedAscending
			}
			return byDateThenID(lhs, rhs)
		}
	}

	/// Newest first, terminating on `entityId`.
	///
	/// The terminator is what makes the chain a strict total order: Swift's `sort(by:)` is not
	/// documented as stable, so without it two findings sharing a key (and a timestamp -- the
	/// import path copies those wholesale) would be free to swap places between renders.
	private static func byDateThenID(_ lhs: Decorated, _ rhs: Decorated) -> Bool {
		switch (lhs.date, rhs.date) {
		case let (left?, right?) where left != right:
			return left > right
		case (nil, _?):
			return false
		case (_?, nil):
			return true
		default:
			return lhs.id < rhs.id
		}
	}
}

// MARK: - Detail

/// One stored finding: the full snapshot with the detection highlighted live
/// (drawn from the stored bounding box — never baked into the image), the
/// editable text fields, and the way back to the captured page. Edits are
/// committed by the explicit Save button — never implicitly on navigation.
private struct FindingDetailView: View {
	@Environment(\.managedObjectContext) private var moc
	/// Held only to hand on to the share composer's own sheet, which needs it live (AIA-0650).
	@EnvironmentObject private var featureFlags: FeatureFlagsState
	@ObservedObject var finding: Finding
	/// Edits commit through the repository rather than straight to the context, so sync hears about
	/// them the moment they land instead of on the next unrelated trigger (AIA-737).
	let findingRepository: FindingRepository
	let onOpenPage: (URL) -> Void

	@State private var title = ""
	@State private var label = ""
	@State private var note = ""
	/// The finder's credit (AIA-0651). Seeded from the stored value only — never from the signed-in
	/// account: prefill is a capture-time convenience, and re-applying it here would rewrite the
	/// credit on findings captured by, or already shared with, someone else.
	@State private var author = ""
	@State private var gps = ""
	@State private var saveFailed = false

	@State private var shareSubject: FindingShareSubject?

	/// Inspect-only view state for the stored snapshot — never persisted (the
	/// stored image/box are fixed; the save sheet owns crop editing).
	@State private var highlightOpacity: Double = 1
	@State private var snapshotZoom: CGFloat = 1

	var body: some View {
		List {
			// Title first, matching the save sheet (AIA-0757 E2). It is the finding's name, and the
			// name belongs above the picture in both places — reading one form and editing the other
			// should not mean hunting for the same field in a different position.
			titleSection
			snapshotSection
			labelSection
			noteSection
			authorSection
			gpsSection
			detectionSection
			pageSection
		}
		.navigationTitle(finding.displayTitle)
		.navigationBarTitleDisplayMode(.inline)
		.toolbar { toolbarContent }
		.alert(L10n.Finding.Save.error, isPresented: $saveFailed) {
			Button(L10n.Common.ok, role: .cancel) {}
		}
		.sheet(item: $shareSubject) { subject in
			FindingShareComposer(subject: subject)
				// Environment objects do not reliably cross a `.sheet` boundary on Mac (Designed for
				// iPad) — re-inject, per AGENTS.md §3.
				.environmentObject(featureFlags)
		}
		.onAppear(perform: seedFields)
	}

	@ViewBuilder
	private var snapshotSection: some View {
		Section {
			if let image = FindingScreenshotStore.load(filename: finding.screenshotFilename) {
				InspectableHighlightedSnapshot(
					image: image,
					normalizedBox: finding.normalizedBox,
					color: .red,
					zoom: $snapshotZoom,
					highlightOpacity: $highlightOpacity
				)
				// Definite height: the cover layout uses a GeometryReader, which
				// collapses to nothing under a maxHeight cap inside a List row.
				.frame(height: 420)
				opacitySlider
				zoomSlider
			} else {
				Image(systemName: "photo")
					.font(.largeTitle)
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity)
					.padding(.vertical, 32)
			}
		}
	}

	private var titleSection: some View {
		Section(L10n.Finding.title) {
			TextField(L10n.Finding.titlePlaceholder, text: $title)
				.testability(Testability.TextField.findingDetailTitle)
		}
	}

	private var labelSection: some View {
		Section(L10n.Finding.label) {
			TextField(L10n.Finding.labelPlaceholder, text: $label)
				.testability(Testability.TextField.findingDetailLabel)
		}
	}

	private var noteSection: some View {
		Section(L10n.Finding.note) {
			TextField(L10n.Finding.notePlaceholder, text: $note, axis: .vertical)
				.lineLimit(3...6)
				.testability(Testability.TextField.findingDetailNote)
		}
	}

	private var authorSection: some View {
		Section(L10n.Finding.author) {
			TextField(L10n.Finding.authorPlaceholder, text: $author)
				.testability(Testability.TextField.findingDetailAuthor)
		}
	}

	private var gpsSection: some View {
		Section(L10n.Finding.gps) {
			TextField(L10n.Finding.gpsPlaceholder, text: $gps)
				.keyboardType(.numbersAndPunctuation)
				.testability(Testability.TextField.findingDetailGps)
		}
	}

	@ViewBuilder
	private var detectionSection: some View {
		if let detectionClass = finding.detectionClass {
			Section(L10n.Finding.detection) {
				// verbatim: class names are model vocabulary, not localizable —
				// and plain interpolation gets auto-extracted into the catalog.
				Text(verbatim: "\(detectionClass) (\(Int(finding.detectionConfidence * 100))%)")
					.foregroundStyle(.secondary)
			}
		}
	}

	@ViewBuilder
	private var pageSection: some View {
		if let page = finding.page {
			Section(L10n.Finding.page) {
				Text(page.absoluteString)
					.font(.caption)
					.foregroundStyle(.secondary)
					.contextMenu {
						Button {
							UIPasteboard.general.string = page.absoluteString
						} label: {
							Label(L10n.Common.copy, systemImage: "doc.on.doc")
						}
					}
				Button {
					onOpenPage(page)
				} label: {
					Label(L10n.Findings.openPage, systemImage: "safari")
				}
				.testability(Testability.Button.findingsOpenPage)
			}
		}
	}

	@ToolbarContentBuilder
	private var toolbarContent: some ToolbarContent {
		ToolbarItemGroup(placement: .navigationBarTrailing) {
			Button(action: shareFinding) {
				Label(L10n.Common.share, systemImage: "square.and.arrow.up")
			}
			.tint(.blue)
			.testability(Testability.Button.findingDetailShare)
			Button(action: saveEdits) {
				Text(L10n.Finding.Save.action)
					.bold()
			}
			.disabled(hasChanges.not || trimmedTitle.isEmpty)
			.tint(.green)
			.testability(Testability.Button.findingDetailSave)
		}
	}

	private func shareFinding() {
		shareSubject = FindingShareSubject(finding)
	}

	private var opacitySlider: some View {
		HStack(spacing: 12) {
			Image(systemName: "square.dashed")
				.foregroundStyle(.secondary)
			Slider(value: $highlightOpacity, in: 0...1)
				.testability(Testability.Slider.findingDetailHighlightOpacity)
		}
		.accessibilityLabel(L10n.Finding.highlightOpacity)
	}

	private var zoomSlider: some View {
		HStack(spacing: 12) {
			Image(systemName: "plus.magnifyingglass")
				.foregroundStyle(.secondary)
			Slider(value: $snapshotZoom, in: InspectableHighlightedSnapshot.zoomRange)
				.testability(Testability.Slider.findingDetailZoom)
		}
		.accessibilityLabel(L10n.Finding.zoom)
	}

	// MARK: - Editing

	private var hasChanges: Bool {
		trimmedTitle != finding.title
			|| normalized(label) != finding.label_
			|| normalized(note) != finding.note_
			|| normalized(author) != finding.author
			|| normalized(gps) != finding.gps_
	}

	private var trimmedTitle: String {
		title.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private func seedFields() {
		title = finding.title
		label = finding.label_ ?? ""
		note = finding.note_ ?? ""
		author = finding.author ?? ""
		gps = finding.gps_ ?? ""
	}

	private func saveEdits() {
		finding.title = trimmedTitle
		finding.label_ = normalized(label)
		finding.note_ = normalized(note)
		finding.author = normalized(author)
		finding.gps_ = normalized(gps)
		do {
			try findingRepository.commitEdits()
		} catch {
			LoggingPolicy.error("Failed to save finding edits", error: error, logger: .storage)
			// Reload from the store so the fields reflect the persisted state
			// instead of silently diverging from it (ConfigurationRow precedent).
			moc.refresh(finding, mergeChanges: false)
			seedFields()
			saveFailed = true
		}
	}

	private func normalized(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}
}

// MARK: - Inspectable snapshot

/// Read-only zoom/pan inspector for a stored snapshot, with an adjustable
/// highlight opacity. Nothing here is persisted — the stored image and box are
/// fixed (the save sheet's `CropAdjustableSnapshot` owns crop editing; this
/// shares the same pan/zoom math but publishes no crop).
private struct InspectableHighlightedSnapshot: View {
	let image: UIImage
	let normalizedBox: CGRect
	let color: Color
	@Binding var zoom: CGFloat
	@Binding var highlightOpacity: Double

	@State private var offset: CGSize = .zero
	@GestureState private var pinchFactor: CGFloat = 1
	@GestureState private var dragDelta: CGSize = .zero

	static let zoomRange: ClosedRange<CGFloat> = 1...8

	var body: some View {
		GeometryReader { geometry in
			content(fitted: geometry.size)
		}
		.frame(maxWidth: .infinity)
	}

	@ViewBuilder
	private func content(fitted: CGSize) -> some View {
		let scale = clampZoom(zoom * pinchFactor)
		// Aspect-fill: the image covers the whole container (no letterbox); overflow
		// is clipped. Zoom/pan then operate on the covered image.
		let cover = fitted.coverSize(for: image.size)
		let shownOffset = clampOffset(
			CGSize(width: offset.width + dragDelta.width, height: offset.height + dragDelta.height),
			scale: scale,
			cover: cover,
			fitted: fitted
		)
		let base = ZStack {
			Image(uiImage: image)
				.resizable()
				.frame(width: cover.width, height: cover.height)
			highlight(in: cover, scale: scale)
		}
		.frame(width: cover.width, height: cover.height)
		.scaleEffect(scale)
		.offset(shownOffset)
		.frame(width: fitted.width, height: fitted.height)
		.clipped()
		.contentShape(Rectangle())
		.gesture(pinch(cover: cover, fitted: fitted))
		.onTapGesture(count: 2) {
			zoom = 1
			offset = .zero
		}

		// Pan only once zoomed in — at scale 1 a drag would just steal scrolling.
		if zoom > 1.001 {
			base.highPriorityGesture(drag(cover: cover, fitted: fitted))
		} else {
			base
		}
	}

	private func highlight(in cover: CGSize, scale: CGFloat) -> some View {
		let rect = normalizedBox.visionRect(in: cover)
		return Rectangle()
			.stroke(color.opacity(highlightOpacity), lineWidth: 2 / scale)
			.frame(width: rect.width, height: rect.height)
			.position(x: rect.midX, y: rect.midY)
	}

	private func pinch(cover: CGSize, fitted: CGSize) -> some Gesture {
		MagnificationGesture()
			.updating($pinchFactor) { value, state, _ in state = value }
			.onEnded { value in
				zoom = clampZoom(zoom * value)
				offset = clampOffset(offset, scale: zoom, cover: cover, fitted: fitted)
			}
	}

	private func drag(cover: CGSize, fitted: CGSize) -> some Gesture {
		DragGesture()
			.updating($dragDelta) { value, state, _ in state = value.translation }
			.onEnded { value in
				offset = clampOffset(
					CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
					scale: zoom,
					cover: cover,
					fitted: fitted
				)
			}
	}

	private func clampZoom(_ value: CGFloat) -> CGFloat {
		min(max(Self.zoomRange.lowerBound, value), Self.zoomRange.upperBound)
	}

	/// Keeps the scaled, covered image from revealing an edge inside the viewport.
	private func clampOffset(_ value: CGSize, scale: CGFloat, cover: CGSize, fitted: CGSize) -> CGSize {
		let maxX = max(0, (cover.width * scale - fitted.width) / 2)
		let maxY = max(0, (cover.height * scale - fitted.height) / 2)
		return CGSize(
			width: min(max(-maxX, value.width), maxX),
			height: min(max(-maxY, value.height), maxY)
		)
	}
}

// MARK: - Mac-only context menu

private extension View {
	/// Attaches a context menu only when running on a Mac. Right-click is the Mac idiom, and it is
	/// the only pointer-reachable route to actions a mouse cannot swipe to. On touch the menu is
	/// suppressed — the row's swipe actions serve instead.
	@ViewBuilder
	func macContextMenu<MenuItems: View>(@ViewBuilder _ menuItems: () -> MenuItems) -> some View {
		if ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp {
			contextMenu(menuItems: menuItems)
		} else {
			self
		}
	}
}

// MARK: - Cover sizing

extension CGSize {
	/// The size the given image must be scaled to so it fully COVERS `self`
	/// (aspect-fill) — the larger dimension overflows and is clipped by the caller.
	func coverSize(for imageSize: CGSize) -> CGSize {
		guard imageSize.width > 0, imageSize.height > 0 else { return self }
		let scale = max(width / imageSize.width, height / imageSize.height)
		return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
	}
}

// MARK: - Crop helpers

extension Finding {
	/// The user-facing name. `title` is required for new findings; the fallback
	/// only covers any legacy/empty (or whitespace-only) row so the list never
	/// shows a blank line.
	var displayTitle: String {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? (label_ ?? detectionClass ?? L10n.Finding.detection) : trimmed
	}

	/// The stored bounding box as a Vision-normalized rect **in the stored screenshot's own
	/// coordinates** — which is the crop, on any finding saved through the crop editor. Every
	/// renderer that draws it over `screenshotFilename`'s image wants exactly this.
	var normalizedBox: CGRect {
		CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
	}

	/// Where the detection sat on the **captured view**, before the crop was baked in — the one
	/// thing a share link can honestly tell a recipient, who has no crop to resolve the other
	/// rect against (AIA-0761).
	///
	/// `.zero` when it was never recorded (a row saved before the attribute existed, or one
	/// imported from an older client's archive). `FindingShareLink.Box` refuses a zero-area box,
	/// so those links carry none rather than a wrong one.
	var captureNormalizedBox: CGRect {
		CGRect(x: captureBoxX, y: captureBoxY, width: captureBoxWidth, height: captureBoxHeight)
	}

	/// Cropped detection thumbnail from the stored snapshot. The pixel rect is
	/// computed against the cgImage's own dimensions — multiplying a pixel-based
	/// rect by `UIImage.scale` would double-scale it.
	func cropThumbnail() -> UIImage? {
		guard
			let image = FindingScreenshotStore.load(filename: screenshotFilename),
			let cgImage = image.cgImage
		else { return nil }
		let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
		// `.integral` can round an edge-touching rect past the image bounds;
		// intersect so the crop request is always fully inside (croppedCapture
		// in SaveFindingSheet does the same).
		let pixelRect = normalizedBox.visionRect(in: bounds.size).integral.intersection(bounds)
		guard pixelRect.width > 0, pixelRect.height > 0, let crop = cgImage.cropping(to: pixelRect) else { return nil }
		return UIImage(cgImage: crop)
	}
}
