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
struct SupportRequestView: View {
	/// Preselected when the request starts from the screenshot offer, where we already know the
	/// user is reporting something broken. `nil` from Settings → About → Contact, where the user
	/// should say what it is about themselves.
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

				Section {
					Toggle(L10n.Support.includeApplicationLog, isOn: $includeApplicationLog)
						.testability(Testability.Toggle.supportRequestIncludeApplicationLog)
					Text(L10n.Support.includeApplicationLogExplanation)
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
		guard includeApplicationLog else {
			// Not merely forgotten: a previous export may hold unredacted data the user has since
			// switched off, and it must not sit in the container waiting to be shared by accident.
			await Task.detached(priority: .utility) { Self.removeApplicationLogExports() }.value
			return
		}
		isPreparingApplicationLogExport = true
		defer { isPreparingApplicationLogExport = false }
		// `Task.detached` is not a child, so `.task(id:)` cancelling this function does NOT cancel
		// the work below. Without a generation check, a superseded run finishes after a newer one
		// deleted the exports and re-creates the file — flip "send unredacted" on and off quickly and
		// an unredacted export reappears under a form that reads redacted. The generation is claimed
		// before the work starts and re-checked before the file is kept.
		let generation = Self.claimApplicationLogExportGeneration()
		let url = await Task.detached(priority: .userInitiated) { () -> URL? in
			let logData = LoggingPolicy.recentApplicationLogData(sendUnredactedData: sendUnredacted)
			return Self.exportedApplicationLogFile(
				data: logData,
				sendUnredactedData: sendUnredacted,
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
		if includeApplicationLog {
			// Off the main actor: the log is read from disk and, unless the user opted into raw
			// data, every line is run through `LogRedactor` — on the order of a second for a full
			// five MiB. Building the attachment happens here too, because a log over the
			// compression threshold is written out, zipped and read back. This view is
			// `@MainActor`, so doing any of it inline would freeze the sheet.
			let sendUnredacted = sendUnredactedApplicationLog
			let applicationLogAttachment = await Task.detached(priority: .userInitiated) {
				let logData = LoggingPolicy.recentApplicationLogData(sendUnredactedData: sendUnredacted)
				return Self.applicationLogAttachment(data: logData, sendUnredactedData: sendUnredacted)
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

	/// Never returns `nil` for a user who asked for the log.
	///
	/// An empty log used to mean no attachment at all: the mail went out with the toggle on and
	/// nothing attached, and neither the user nor support could tell "quiet session" from "the log
	/// was lost" (a full disk, a directory that could not be created). One placeholder line is
	/// cheap and says which (AIA-0602).
	///
	/// Above ``applicationLogCompressionThresholdBytes`` the log is attached as a zip: plain text
	/// compresses by an order of magnitude, and a five-MiB attachment is the kind of thing a mail
	/// provider bounces. Below it the raw text stays, because a small log is worth more to support
	/// readable inline than compressed.
	nonisolated static func applicationLogAttachment(
		data: Data,
		sendUnredactedData: Bool
	) -> EmailController.Attachment? {
		guard data.isEmpty == false else {
			return EmailController.Attachment(
				data: Data(emptyApplicationLogPlaceholder.utf8),
				mimeType: "text/plain",
				fileName: "mlbrowser-application-log-unavailable.txt"
			)
		}
		let fileName = applicationLogFileName(sendUnredactedData: sendUnredactedData)
		if data.count > applicationLogCompressionThresholdBytes,
		   let compressed = zippedApplicationLog(data: data, fileName: fileName),
		   compressed.isEmpty == false,
		   compressed.count < data.count {
			return EmailController.Attachment(
				data: compressed,
				mimeType: "application/zip",
				fileName: fileName + ".zip"
			)
		}
		// Reached whenever the payload is small, the zip failed, or the archive came out no smaller
		// than the input: none of those is a reason to send nothing.
		return EmailController.Attachment(
			data: data,
			mimeType: "text/plain",
			fileName: fileName
		)
	}

	/// One MiB. Chosen so an ordinary session still arrives as readable text while a full five-MiB
	/// log — the case that makes the mail unwieldy — is compressed.
	nonisolated static let applicationLogCompressionThresholdBytes = 1_024 * 1_024

	/// One line rather than nothing, so a quiet session and a lost log cannot look alike (AIA-0602).
	nonisolated static let emptyApplicationLogPlaceholder =
		"The application log was empty or unavailable when this report was composed.\n"

	/// The filename has to state which form the bytes are in: nobody receiving a log can tell
	/// redacted content from unredacted content by reading it.
	nonisolated static func applicationLogFileName(sendUnredactedData: Bool) -> String {
		sendUnredactedData
			? "mlbrowser-application-log-unredacted.txt"
			: "mlbrowser-application-log.txt"
	}

	/// Zips the log with the file coordinator's upload intent — a real `.zip`, no third-party
	/// dependency. Returns `nil` on any failure so the caller falls back to plain text; a bulky
	/// attachment beats a missing one.
	///
	/// The coordinator is pointed at a **directory** holding the log, because that is the case
	/// documented to produce an archive; a lone regular file can be handed back unchanged.
	nonisolated static func zippedApplicationLog(data: Data, fileName: String) -> Data? {
		let fileManager = FileManager.default
		let staging = fileManager.temporaryDirectory
			.appendingPathComponent("mlbrowser-log-zip-\(UUID().uuidString)", isDirectory: true)
		let archiveRoot = staging
			.appendingPathComponent((fileName as NSString).deletingPathExtension, isDirectory: true)
		defer { try? fileManager.removeItem(at: staging) }
		do {
			try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
			try data.write(to: archiveRoot.appendingPathComponent(fileName), options: .atomic)
			var coordinationError: NSError?
			var archived: Result<Data, Error>?
			NSFileCoordinator().coordinate(
				readingItemAt: archiveRoot,
				options: [.forUploading],
				error: &coordinationError
			) { archiveURL in
				// Read inside the accessor: the archive is the coordinator's own temporary file and
				// is gone once this block returns. Fully read, never memory-mapped, for that reason.
				archived = Result { try Data(contentsOf: archiveURL) }
			}
			if let coordinationError { throw coordinationError }
			return try archived?.get()
		} catch {
			// `.debug`, not `.warning`: warning breadcrumbs unconditionally, and AIA-0602 requires
			// production Sentry volume to be unchanged. The fallback is already safe, so this is a
			// diagnostic note, not an alert.
			LoggingPolicy.debug(
				"Could not compress the application log (\(error.localizedDescription)) — attaching plain text",
				logger: .ui
			)
			return nil
		}
	}

	/// Where ``exportedApplicationLogFile(data:sendUnredactedData:)`` puts the file it hands to
	/// `ShareLink`. Inside the app's temporary directory: sandboxed, and purged by the system.
	private nonisolated static var applicationLogExportDirectory: URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("support-log-export", isDirectory: true)
	}

	/// Writes the log under the name that says whether it is redacted, and returns it for sharing.
	/// `nil` (logged) rather than a throw: the caller's only recourse either way is to leave the row
	/// with nothing to share.
	///
	/// Shared as plain text at any size — this is the "save it to Files" route, where readability is
	/// the point; compression is an email concern (see ``applicationLogAttachment(data:sendUnredactedData:)``).
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
		generation: Int? = nil
	) -> URL? {
		let fileManager = FileManager.default
		let directory = applicationLogExportDirectory
		let url = directory
			.appendingPathComponent(applicationLogFileName(sendUnredactedData: sendUnredactedData))
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
				let payload = data.isEmpty ? Data(emptyApplicationLogPlaceholder.utf8) : data
				try payload.write(to: url, options: .atomic)
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

	/// Drops any previously written export. The file can hold unredacted log data, so it must not
	/// outlive the choice that produced it.
	nonisolated static func removeApplicationLogExports() {
		applicationLogExportQueue.sync { removeApplicationLogExportsLocked() }
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
