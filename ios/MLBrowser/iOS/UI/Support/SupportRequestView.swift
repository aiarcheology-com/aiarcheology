//
//  SupportRequestView.swift
//  AI Archeology
//
//  Structured support requests (AIA-0440 Stage 1, AIA-0454).
//

import SwiftUI
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
	static let minimumShortestSidePixels = 720

	static func isLargeEnough(pixelWidth: Int, pixelHeight: Int) -> Bool {
		min(pixelWidth, pixelHeight) >= minimumShortestSidePixels
	}

	static func isLargeEnough(imageData: Data) -> Bool {
		guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
			  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
			  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
			return false
		}
		return isLargeEnough(pixelWidth: width.intValue, pixelHeight: height.intValue)
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
	/// Whether the mailto: fallback actually reached a mail app — decides which unavailable
	/// message is honest: "we opened your mail app (without the screenshot)" vs "nothing to open".
	@State private var mailtoOpened = false
	@State private var showCopiedConfirmation = false

	/// Held so the fallback can put the exact same text on the clipboard that the composer would
	/// have carried — the user's work must survive a missing mail account.
	@State private var composedRequest: SupportRequest?

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
				}

				Section {
					// `PhotosPicker` runs out-of-process, so it needs no photo-library permission
					// and no NSPhotoLibraryUsageDescription: the app only ever receives the single
					// image the user hands it. Notably NOT `Gallery/PhotoPicker.swift`, which is a
					// gallery importer — it copies the pick into Documents and appends it to the
					// user's gallery, which filing a bug report must not do.
					PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
						Label(
							attachment == nil ? L10n.Support.attachScreenshot : L10n.Support.attachedScreenshot,
							systemImage: attachment == nil ? "photo.badge.plus" : "checkmark.circle.fill"
						)
					}
				}

				Section {
					Button(L10n.Support.compose) {
						Task { await compose() }
					}
					.buttonStyle(.borderedProminent)
					.tint(.green)
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
		}
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
			guard ScreenshotAttachmentValidator.isLargeEnough(imageData: data) else {
				LoggingPolicy.info("Picked screenshot is too small to attach to a support report.", logger: .ui)
				showScreenshotTooSmallNotice = true
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
			LoggingPolicy.info(
				sendUnredactedApplicationLog
					? "User chose to include unredacted application data with a support report."
					: "User chose to include the redacted application log with a support report.",
				logger: .ui
			)
			attachments.append(applicationLogAttachment(sendUnredactedData: sendUnredactedApplicationLog))
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

	private func applicationLogAttachment(sendUnredactedData: Bool) -> EmailController.Attachment {
		EmailController.Attachment(
			data: LoggingPolicy.recentApplicationLogData(sendUnredactedData: sendUnredactedData),
			mimeType: "text/plain",
			fileName: sendUnredactedData
				? "mlbrowser-application-log-unredacted.txt"
				: "mlbrowser-application-log.txt"
		)
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
