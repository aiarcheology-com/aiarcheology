//
//  SupportRequestView.swift
//  AI Archeology
//
//  Structured support requests (AIA-0440 Stage 1, AIA-0454).
//

import SwiftUI
import Foundation
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import ClerkKit

/// Validates an image selected for a support email without decoding its full pixel buffer.
///
/// A report is useful only if support can inspect the visual defect. A 720-pixel shortest edge
/// accepts screenshots from every supported iPhone while rejecting small thumbnails that become
/// pixelated when viewed in an email.
enum ScreenshotAttachmentValidator {
	enum ValidationResult: Equatable {
		case accepted
		case tooSmall
		case unreadable
	}

	static let minimumShortestSidePixels = 720

	static func isLargeEnough(pixelWidth: Int, pixelHeight: Int) -> Bool {
		min(pixelWidth, pixelHeight) >= minimumShortestSidePixels
	}

	static func validationResult(imageData: Data) -> ValidationResult {
		guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
			  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
			  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
			return .unreadable
		}
		return isLargeEnough(pixelWidth: width.intValue, pixelHeight: height.intValue)
			? .accepted
			: .tooSmall
	}
}

/// Collects a support request and hands it to the user's mail app.
///
/// The screen deliberately stops at "compose": it never sends anything. The user reads the whole
/// email — technical details and any screenshot included — in the system composer, edits what they
/// like, and sends it from their own account. That reviewability is what keeps prefilled
/// diagnostics (including the web address, which is the single most useful clue for a browser bug)
/// consent-clean. See ``SupportRequest`` for the full argument.
///
/// The argument above covers the **email body** — the diagnostics the user actually reads in the
/// composer. It never really covered the log attachment, which no one was going to read five MiB
/// of, and since AIA-0643 that attachment is sealed and unreadable to them.
///
/// That is a privacy improvement, not a reduction: the file used to be readable by every mail relay
/// it passed through and by anyone the user forwarded it to. The controls that matter are unchanged
/// — attach it or not, redacted or not, and remove it in the composer. No copy on this screen
/// mentions the encryption, deliberately; the disclosure lives in the hosted privacy policy
/// (AIA-0624, §2 and §3.5), which is where "what leaves my device and who can read it" belongs.
struct SupportRequestView: View {
	/// Preselected when the request starts from the screenshot offer, where we already know the
	/// user is reporting something broken. `nil` from Settings → About the app → Report a problem →
	/// Send email, where the user should say what it is about themselves.
	let initialCategory: SupportCategory?

	/// The web address involved in the problem, when the caller knows one.
	let contextURL: String?

	@Environment(\.dismiss) private var dismiss
	@Environment(\.usesRealAuth) private var usesRealAuth

	@State private var category: SupportCategory
	@State private var pickedPhoto: PhotosPickerItem?
	@State private var attachment: EmailController.Attachment?
	@State private var includeApplicationLog = false
	@State private var sendUnredactedApplicationLog = false
	@State private var showMailUnavailableNotice = false
	@State private var showScreenshotTooSmallNotice = false
	@State private var showScreenshotUnreadableNotice = false
	/// Whether the mailto: fallback actually reached a mail app — decides which unavailable
	/// message is honest: "we opened your mail app (without the screenshot)" vs "nothing to open".
	@State private var mailtoOpened = false
	@State private var showCopiedConfirmation = false

	/// Guards the compose button while the request is being assembled (AIA-0602). Reading the
	/// application log became slow enough to double-tap through.
	@State private var isComposing = false

	/// Held so the fallback can put the exact same text on the clipboard that the composer would
	/// have carried — the user's work must survive a missing mail account.
	@State private var composedRequest: SupportRequest?

	/// The temporary file `ShareLink` hands to Files/AirDrop/Messages. `nil` until the log has been
	/// gathered and written, which is why the row shows progress rather than a dead share button.
	@State private var applicationLogExportURL: URL?
	@State private var isPreparingApplicationLogExport = false

	private let recipient = SupportRequest.supportEmailAddress

	init(initialCategory: SupportCategory? = nil, contextURL: String? = nil) {
		self.initialCategory = initialCategory
		self.contextURL = contextURL
		_category = State(initialValue: initialCategory ?? .bug)
	}

	var body: some View {
		NavigationStack {
			Form {
				Section(L10n.Support.categoryPrompt) {
					Picker(L10n.Support.categoryPrompt, selection: $category) {
						ForEach(SupportCategory.allCases) { option in
							Text(option.displayName).tag(option)
						}
					}
					.labelsHidden()
					.pickerStyle(.inline)
				}

				// Conditional on a usable key, and withdrawn rather than downgraded without one:
				// the only alternative to sealing is exporting the log in the clear, which is the
				// thing AIA-0643 exists to stop. A build with no configured key therefore offers no
				// log at all, and does it quietly — no alert, no error row, nothing for the user to
				// act on, because there is nothing they could do about it. See ``SupportLogSealer``.
				if Self.sealer != nil {
					Section {
						Toggle(L10n.Support.includeApplicationLog, isOn: $includeApplicationLog)
							.testability(Testability.Toggle.supportRequestIncludeApplicationLog)
						Text(L10n.Support.ApplicationLog.explanation)
							.foregroundStyle(.blue)
							.fixedSize(horizontal: false, vertical: true)
						Toggle(L10n.Support.sendUnredactedData, isOn: $sendUnredactedApplicationLog)
							.disabled(!includeApplicationLog)
							.testability(Testability.Toggle.supportRequestSendUnredactedData)
						Text(L10n.Support.sendUnredactedDataExplanation)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
						if includeApplicationLog {
							applicationLogShareRow
						}
					}
				}

				Section {
					// `PhotosPicker` runs out-of-process, so it needs no photo-library permission
					// and no NSPhotoLibraryUsageDescription: the app only ever receives the single
					// image the user hands it. Notably NOT `Gallery/PhotoPicker.swift`, which is a
					// gallery importer — it copies the pick into Documents and appends it to the
					// user's gallery, which filing a bug report must not do.
					// Read once here, on the main actor, and capture the result. `attachment` is
					// `@State` and therefore main-actor isolated, while `PhotosPicker`'s label
					// closure is `@Sendable` — reading it inside warns today and is an error under
					// Swift 6 language mode. A captured `Bool` crosses that boundary safely and the
					// rendered label is identical (AIA-0634).
					let hasAttachment = attachment != nil
					PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
						Label(
							hasAttachment ? L10n.Support.attachedScreenshot : L10n.Support.attachScreenshot,
							systemImage: hasAttachment ? "checkmark.circle.fill" : "photo.badge.plus"
						)
					}
				}

				Section {
					// Disabled while composing: gathering the log is no longer instant (it reads up
					// to five MiB from disk and redacts it), and a second tap would build a second
					// request and try to present a second composer over the first.
					Button(L10n.Support.compose) {
						Task { await compose() }
					}
					.buttonStyle(.borderedProminent)
					.tint(.green)
					.frame(maxWidth: .infinity, alignment: .center)
					.disabled(isComposing)
				} footer: {
					Text(L10n.Support.privacyNote)
						.font(.body)
						.foregroundStyle(.primary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.navigationTitle(L10n.Support.title)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(L10n.Common.cancel) { dismiss() }
				}
			}
			.task(id: pickedPhoto) { await loadPickedPhoto() }
			// Keyed on both toggles: the shared file must never lag behind the choice, or the user
			// would AirDrop redacted bytes from a name that promises unredacted ones (or worse, the
			// other way round).
			.task(id: ApplicationLogExportKey(
				isIncluded: includeApplicationLog,
				isUnredacted: sendUnredactedApplicationLog
			)) {
				await prepareApplicationLogExport()
			}
			.onChange(of: includeApplicationLog) { _, isIncludingLog in
				if !isIncludingLog {
					sendUnredactedApplicationLog = false
				}
			}
			// Not a dead end: `canSendMail()` is false whenever Mail.app has no account — and the
			// user cannot be sent straight to Mail's setup pane, because iOS exposes no such URL
			// (`openSettingsURLString` only opens THIS app's page, and `App-Prefs:root=MAIL` is
			// undocumented and an App Review risk). So offer the two things that do work: the
			// Settings app, and a clipboard copy so the report survives either way.
			.alert(L10n.Support.MailUnavailable.title, isPresented: $showMailUnavailableNotice) {
				Button(L10n.Support.openSettings) { openAppSettings() }
				Button(L10n.Support.copyReport) { copyReport() }
				Button(L10n.Common.ok, role: .cancel) { dismiss() }
			} message: {
				Text(
					mailtoOpened
						? L10n.Support.MailUnavailable.message(recipient)
						: L10n.Support.MailUnavailable.messageNoMailApp(recipient)
				)
			}
			.alert(L10n.Support.title, isPresented: $showCopiedConfirmation) {
				Button(L10n.Common.ok, role: .cancel) { dismiss() }
			} message: {
				Text(L10n.Support.reportCopied(recipient))
			}
			.alert(L10n.Support.ScreenshotTooSmall.title, isPresented: $showScreenshotTooSmallNotice) {
				Button(L10n.Common.ok, role: .cancel) {}
			} message: {
				Text(L10n.Support.ScreenshotTooSmall.message(ScreenshotAttachmentValidator.minimumShortestSidePixels))
			}
			.alert(L10n.Support.ScreenshotUnreadable.title, isPresented: $showScreenshotUnreadableNotice) {
				Button(L10n.Common.ok, role: .cancel) {}
			} message: {
				Text(L10n.Support.ScreenshotUnreadable.message)
			}
		}
	}

	/// Identifies the export the sheet currently needs. `task(id:)` regenerates the file whenever
	/// either toggle moves.
	private struct ApplicationLogExportKey: Equatable {
		let isIncluded: Bool
		let isUnredacted: Bool
	}

	/// Saving or sharing the log is the only route off the device for a user with no mail account:
	/// the `mailto:` fallback in ``compose()`` carries no attachments (RFC 6068), so until now those
	/// users could not send the log at all (AIA-0602).
	///
	/// A file URL, not a string: the recipient gets a filename that states whether the contents are
	/// redacted, and five MiB never passes through the activity payload.
	@ViewBuilder
	private var applicationLogShareRow: some View {
		if let applicationLogExportURL {
			ShareLink(item: applicationLogExportURL) {
				Label(L10n.Support.shareApplicationLog, systemImage: "square.and.arrow.up")
			}
			.testability(Testability.Button.supportRequestShareApplicationLog)
		} else {
			// Still gathering, or the file could not be written. Either way there is nothing to
			// share yet, and a share button pointing at a missing file is worse than none.
			HStack {
				Label(L10n.Support.shareApplicationLog, systemImage: "square.and.arrow.up")
					.foregroundStyle(.secondary)
				Spacer()
				if isPreparingApplicationLogExport {
					ProgressView()
				}
			}
		}
	}

	/// Writes the log the user would send to a temporary file so `ShareLink` has something to hand
	/// over. Off the main actor for the reason ``compose()`` gives: reading and redacting a full log
	/// costs about a second, and this view is `@MainActor`.
	private func prepareApplicationLogExport() async {
		applicationLogExportURL = nil
		let sendUnredacted = sendUnredactedApplicationLog
		// Claimed unconditionally, and BEFORE the `includeApplicationLog` check.
		//
		// `Task.detached` is not a child, so `.task(id:)` cancelling this function does NOT cancel
		// the work below. Without a generation check a superseded run finishes after a newer one
		// deleted the exports and recreates the file. The subtle half is the "switched off" branch:
		// it used to remove the exports without claiming a generation, so an in-flight run still
		// held the current number, passed its check, and wrote the file the newer run had just
		// deleted — leaving an export behind after the user turned the toggle off. Claiming here
		// invalidates any run already in flight, whichever branch we take.
		//
		// This mattered more before AIA-0643: the resurrected file was plaintext, and unredacted.
		// It is now sealed, so the remaining harm is only that a file exists which the user's
		// action said should not. **That downgrade depends entirely on the seal being
		// unconditional** — if a "sealing failed, attach plain text" fallback is ever reintroduced,
		// this becomes a privacy leak again with no test to announce it.
		let generation = Self.claimApplicationLogExportGeneration()
		guard includeApplicationLog, let sealer = Self.sealer else {
			// Not merely forgotten: an export the user switched off must not sit in the container
			// waiting to be shared by accident.
			await Task.detached(priority: .utility) {
				Self.removeApplicationLogExports(generation: generation)
			}.value
			return
		}
		isPreparingApplicationLogExport = true
		defer { isPreparingApplicationLogExport = false }
		let url = await Task.detached(priority: .userInitiated) { () -> URL? in
			let logData = LoggingPolicy.recentApplicationLogData(sendUnredactedData: sendUnredacted)
			return Self.exportedApplicationLogFile(
				data: logData,
				sendUnredactedData: sendUnredacted,
				sealer: sealer,
				generation: generation
			)
		}.value
		guard Task.isCancelled == false, Self.isCurrentApplicationLogExportGeneration(generation) else {
			return
		}
		applicationLogExportURL = url
	}

	/// Loads the image the user picked. Failure is logged, never swallowed: the user explicitly
	/// asked for this attachment, so silently sending without it would misrepresent what they sent.
	///
	/// Every exit clears `attachment` first. Leaving a previous pick in place when a newer one
	/// fails to load would show "Screenshot attached" and then mail the **old** image — sending a
	/// picture the user had already replaced, which is the exact opposite of the control this
	/// whole flow exists to give them.
	private func loadPickedPhoto() async {
		attachment = nil
		guard let pickedPhoto else { return }
		do {
			guard let data = try await pickedPhoto.loadTransferable(type: Data.self) else {
				LoggingPolicy.warning("Picked screenshot produced no data — not attaching", logger: .ui)
				return
			}
			switch ScreenshotAttachmentValidator.validationResult(imageData: data) {
			case .accepted:
				break
			case .tooSmall:
				LoggingPolicy.info("Picked screenshot is too small to attach to a support report.", logger: .ui)
				showScreenshotTooSmallNotice = true
				return
			case .unreadable:
				LoggingPolicy.warning("Picked screenshot could not be read — not attaching", logger: .ui)
				showScreenshotUnreadableNotice = true
				return
			}
			// The declared type, not a hardcoded PNG: `loadTransferable` returns the original
			// encoding, and the picker allows any library image — a camera photo is HEIC, and
			// HEIC bytes labelled image/png may not render for the recipient.
			let contentType = pickedPhoto.supportedContentTypes.first
			attachment = EmailController.Attachment(
				data: data,
				mimeType: contentType?.preferredMIMEType ?? "image/png",
				fileName: "screenshot.\(contentType?.preferredFilenameExtension ?? "png")"
			)
		} catch {
			LoggingPolicy.error("Could not load the picked screenshot: \(error.localizedDescription)", logger: .ui)
		}
	}

	private func compose() async {
		isComposing = true
		defer { isComposing = false }

		let request = SupportRequest(
			category: category,
			contextURL: contextURL,
			accountID: usesRealAuth ? Clerk.shared.user?.id : nil,
			// The bundle's resolved localization, not `Locale.current`: the field is labelled
			// "App language", and iOS lets a user set a per-app language that differs from the
			// device locale. This reports the language the UI is actually rendering in — the
			// thing support needs to reproduce what the user saw.
			appLanguage: Bundle.main.preferredLocalizations.first ?? "unknown",
			appVersion: AppEnvironment.shortVersion ?? "unknown",
			deviceInformation: await DeviceInfo.information()
		)
		composedRequest = request
		var attachments = [attachment].compactMap { $0 }
		if includeApplicationLog, let sealer = Self.sealer {
			// Off the main actor: the log is read from disk and, unless the user opted into raw
			// data, every line is run through `LogRedactor` — on the order of a second for a full
			// five MiB. Sealing happens here too: compressing and encrypting five MiB is not
			// main-thread work either. This view is `@MainActor`, so doing any of it inline would
			// freeze the sheet.
			let sendUnredacted = sendUnredactedApplicationLog
			let applicationLogAttachment = await Task.detached(priority: .userInitiated) {
				let logData = LoggingPolicy.recentApplicationLogData(sendUnredactedData: sendUnredacted)
				return Self.applicationLogAttachment(
					data: logData,
					sendUnredactedData: sendUnredacted,
					sealer: sealer
				)
			}.value
			LoggingPolicy.info(
				sendUnredactedApplicationLog
					? "User chose to include unredacted application data with a support report."
					: "User chose to include the redacted application log with a support report.",
				logger: .ui
			)
			if let applicationLogAttachment {
				attachments.append(applicationLogAttachment)
			}
		}

		do {
			// The sheet must NOT be dismissed here: the composer presents on top of it, so
			// dismissing now would tear the composer down mid-flight. Close only once the
			// composer reports the message was handed to Mail; on cancel the user lands back
			// here with their category and attachment intact, free to retry or leave.
			try EmailController.shared.sendEmail(
				subject: request.subject,
				body: request.body,
				to: recipient,
				attachments: attachments,
				onFinish: { sent in
					if sent { dismiss() }
				}
			)
		} catch {
			// No mail account, or nothing to present from. Fall back to the user's default mail app
			// — which cannot carry attachments (RFC 6068), so say so rather than dropping the
			// screenshot or an opted-in application log silently.
			LoggingPolicy.warning("Mail composer unavailable (\(error)) — falling back to mailto:", logger: .ui)
			mailtoOpened = await EmailController.shared.openMailto(
				subject: request.subject,
				body: request.body,
				to: recipient
			)
			showMailUnavailableNotice = true
		}
	}

	/// The sealer this build ships with, or `nil` when no usable key is configured.
	///
	/// Read through one property so the "is the export available at all?" question has a single
	/// answer that the view, the producer and the tests all consult.
	nonisolated static var sealer: SupportLogSealer? { SupportLogSealer.bundled }

	/// The one sealed artifact both export routes hand over.
	///
	/// There used to be two producers emitting *different formats for the same bytes* — plain text
	/// or a zip for mail depending on a size threshold, always plain text for the share sheet. The
	/// formats no longer differ, so neither do the producers: this returns the bytes and the name,
	/// and the two callers differ only in how they deliver them (`Data` for the mail composer, a
	/// file `URL` for `ShareLink`), which is imposed by those frameworks rather than chosen here.
	///
	/// Compression is unconditional and internal to the envelope, so the threshold that used to
	/// pick between formats has nothing left to decide and is gone.
	///
	/// **Returns `nil` on any failure, and that means no attachment at all.** The code this replaced
	/// argued the opposite in two places — "none of those is a reason to send nothing" and "a bulky
	/// attachment beats a missing one". That instinct is right when the choice is between formats
	/// and catastrophic when it is between sealed and not: the only fallback available here is
	/// plain text, which is exactly what AIA-0643 exists to prevent. Both comments were deleted
	/// rather than reworded so the next reader cannot inherit them.
	nonisolated static func sealedApplicationLog(
		data: Data,
		sendUnredactedData: Bool,
		sealer: SupportLogSealer,
		date: Date = Date()
	) -> (data: Data, fileName: String)? {
		// An empty log still produces a file. Sending nothing left neither the user nor support able
		// to tell a quiet session from a lost log — a full disk, a directory that could not be
		// created (AIA-0602). The placeholder is sealed like anything else, so there is exactly one
		// output format rather than a special case that ships readable bytes.
		let payload = data.isEmpty ? Data(emptyApplicationLogPlaceholder.utf8) : data
		guard let sealed = sealer.seal(
			log: payload,
			redacted: sendUnredactedData == false,
			appVersion: AppEnvironment.shortVersion ?? "unknown",
			buildNumber: AppEnvironment.buildNumber ?? "unknown",
			date: date
		) else { return nil }
		return (sealed, SupportLogSealer.fileName(date: date))
	}

	/// The mail-composer delivery of ``sealedApplicationLog(data:sendUnredactedData:sealer:date:)``.
	nonisolated static func applicationLogAttachment(
		data: Data,
		sendUnredactedData: Bool,
		sealer: SupportLogSealer
	) -> EmailController.Attachment? {
		guard let sealed = sealedApplicationLog(
			data: data, sendUnredactedData: sendUnredactedData, sealer: sealer
		) else { return nil }
		return EmailController.Attachment(
			data: sealed.data,
			mimeType: SupportLogSealer.mimeType,
			fileName: sealed.fileName
		)
	}

	/// One line rather than nothing, so a quiet session and a lost log cannot look alike (AIA-0602).
	nonisolated static let emptyApplicationLogPlaceholder =
		"The application log was empty or unavailable when this report was composed.\n"

	/// Where ``exportedApplicationLogFile(data:sendUnredactedData:sealer:generation:)`` puts the file
	/// it hands to `ShareLink`. Inside the app's temporary directory: sandboxed, and purged by the
	/// system.
	private nonisolated static var applicationLogExportDirectory: URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("support-log-export", isDirectory: true)
	}

	/// Writes the sealed log and returns it for sharing. `nil` (logged) rather than a throw: the
	/// caller's only recourse either way is to leave the row with nothing to share.
	///
	/// This route once shared plain text at any size, on the reasoning that "save it to Files" is
	/// where readability is the point. It is now the same sealed bytes the mail path attaches — the
	/// user's own copy is no more readable than the one we receive, which the share row's copy says
	/// plainly.
	///
	/// Serialises export writes against the generation counter, so a superseded run cannot recreate a
	/// file a newer run removed. Every mutation of the export directory goes through this queue.
	private nonisolated static let applicationLogExportQueue =
		DispatchQueue(label: "com.aiarcheology.ios.support-log-export")
	private nonisolated(unsafe) static var applicationLogExportGeneration = 0

	static func claimApplicationLogExportGeneration() -> Int {
		applicationLogExportQueue.sync {
			applicationLogExportGeneration += 1
			return applicationLogExportGeneration
		}
	}

	static func isCurrentApplicationLogExportGeneration(_ generation: Int) -> Bool {
		applicationLogExportQueue.sync { applicationLogExportGeneration == generation }
	}

	nonisolated static func exportedApplicationLogFile(
		data: Data,
		sendUnredactedData: Bool,
		sealer: SupportLogSealer,
		generation: Int? = nil
	) -> URL? {
		// Sealed before anything touches the filesystem. If sealing fails there is no file at all —
		// writing the plain bytes "so the user has something to share" would hand them the very
		// export this ticket removed.
		guard let sealed = sealedApplicationLog(
			data: data, sendUnredactedData: sendUnredactedData, sealer: sealer
		) else { return nil }
		let fileManager = FileManager.default
		let directory = applicationLogExportDirectory
		let url = directory.appendingPathComponent(sealed.fileName)
		do {
			// Replaced, never accumulated: the previous export may hold unredacted data the user
			// has since switched off.
			try applicationLogExportQueue.sync {
				guard generation == nil || generation == Self.applicationLogExportGeneration else {
					// Superseded while we were reading and redacting. Writing now would resurrect an
					// export the newer run already removed.
					throw CancellationError()
				}
				removeApplicationLogExportsLocked()
				try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
				try sealed.data.write(to: url, options: .atomic)
			}
			return url
		} catch is CancellationError {
			// Superseded, not failed. Nothing to report and nothing to clean up — the newer run owns
			// the directory now.
			return nil
		} catch {
			// `.debug`, not `.error`: error adds a breadcrumb AND spends Sentry event quota via
			// captureError, and AIA-0602 requires production Sentry volume to be unchanged. The user
			// sees the outcome directly — the share row stays disabled.
			LoggingPolicy.debug(
				"Could not write the application log for sharing: \(error.localizedDescription)",
				logger: .ui
			)
			return nil
		}
	}

	/// Drops any previously written export.
	///
	/// The file is sealed now, so this is no longer about readable data escaping. It is about the
	/// user's choice: an export they turned off must not stay in the container waiting to be shared
	/// by accident. ``purgeLegacyApplicationLogExports()`` handles the other half — the readable
	/// files older builds left behind.
	nonisolated static func removeApplicationLogExports(generation: Int? = nil) {
		applicationLogExportQueue.sync {
			// A removal can be superseded exactly as a write can, and the race runs the other way:
			// switch the log off (claims a generation, spawns a `.utility` removal) then straight
			// back on (claims a newer one, spawns a `.userInitiated` writer). The writer spends about
			// a second reading and redacting, so the lower-priority removal can still be waiting when
			// it finishes — and would then delete the *newer* run's file, leaving the share row
			// pointing at a URL with nothing behind it. Skipping when superseded is safe because the
			// newer run clears the directory itself before writing.
			//
			// `nil` means "not part of any run" — the launch purge and tests, which must always
			// remove.
			guard generation == nil || generation == applicationLogExportGeneration else { return }
			removeApplicationLogExportsLocked()
		}
	}

	/// Removes readable log exports that **earlier builds** left in the temporary container.
	///
	/// Before AIA-0643 both export routes wrote plain text, and one of them staged an unencrypted
	/// copy in `mlbrowser-log-zip-<uuid>/` whose cleanup was a `defer` — which a crash skips. iOS
	/// does not wipe `tmp` on update, so upgrading to a build that seals everything does not by
	/// itself remove what the previous build wrote. Those files are not reachable through the app
	/// (there is no `UIFileSharingEnabled`), but leaving readable unredacted logs in the container
	/// after a change made specifically to stop that would be an odd place to draw the line.
	///
	/// Unconditional and independent of the sealer: a build with no key must still clean up, and
	/// this must not wait for the user to open the Support sheet, which they may never do.
	/// Best-effort and silent — a failure here leaves things exactly as the old build did.
	nonisolated static func purgeLegacyApplicationLogExports() {
		let fileManager = FileManager.default
		let temporaryDirectory = fileManager.temporaryDirectory
		removeApplicationLogExports()
		guard let entries = try? fileManager.contentsOfDirectory(
			at: temporaryDirectory,
			includingPropertiesForKeys: nil
		) else { return }
		for entry in entries where entry.lastPathComponent.hasPrefix("mlbrowser-log-zip-") {
			try? fileManager.removeItem(at: entry)
		}
	}

	/// The same work without taking the queue, for callers that already hold it. Re-entering
	/// `queue.sync` from the queue is an unconditional deadlock, not a smell.
	private nonisolated static func removeApplicationLogExportsLocked() {
		try? FileManager.default.removeItem(at: applicationLogExportDirectory)
	}

	/// Opens the Settings app. This lands on **ML Browser's own page**, not Mail's — iOS offers no
	/// public URL for another app's settings, and the undocumented `App-Prefs:root=MAIL` is an App
	/// Review risk. The alert copy therefore names the path (Mail → Mail Accounts) rather than
	/// pretending the button goes straight there.
	private func openAppSettings() {
		guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
		Task { await UIApplication.shared.open(url) }
	}

	/// Puts the whole report on the clipboard so a missing mail account cannot destroy the user's
	/// work — they can paste it into any app, or onto another device.
	private func copyReport() {
		guard let request = composedRequest else { return }
		UIPasteboard.general.string = "\(request.subject)\n\n\(request.body)"
		showCopiedConfirmation = true
	}
}
