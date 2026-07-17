//
//  SupportRequestView.swift
//  AI Archeology
//
//  Structured support requests (AIA-0440 Stage 1, AIA-0454).
//

import SwiftUI
import PhotosUI
import ClerkKit

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
	@State private var showMailUnavailableNotice = false
	/// Whether the mailto: fallback actually reached a mail app — decides which unavailable
	/// message is honest: "we opened your mail app (without the screenshot)" vs "nothing to open".
	@State private var mailtoOpened = false

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
				} footer: {
					Text(L10n.Support.privacyNote)
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
			.alert(L10n.Support.title, isPresented: $showMailUnavailableNotice) {
				Button(L10n.Common.ok, role: .cancel) { dismiss() }
			} message: {
				Text(
					mailtoOpened
						? L10n.Support.MailUnavailable.message(recipient)
						: L10n.Support.MailUnavailable.messageNoMailApp(recipient)
				)
			}
		}
	}

	/// Loads the image the user picked. Failure is logged, never swallowed: the user explicitly
	/// asked for this attachment, so silently sending without it would misrepresent what they sent.
	private func loadPickedPhoto() async {
		guard let pickedPhoto else { return }
		do {
			guard let data = try await pickedPhoto.loadTransferable(type: Data.self) else {
				LoggingPolicy.warning("Picked screenshot produced no data — not attaching", logger: .ui)
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
			appLanguage: Locale.current.language.languageCode?.identifier ?? "unknown",
			appVersion: AppEnvironment.shortVersion ?? "unknown",
			deviceInformation: await DeviceInfo.information()
		)

		do {
			// The sheet must NOT be dismissed here: the composer presents on top of it, so
			// dismissing now would tear the composer down mid-flight. Close only once the
			// composer reports the message was handed to Mail; on cancel the user lands back
			// here with their category and attachment intact, free to retry or leave.
			try EmailController.shared.sendEmail(
				subject: request.subject,
				body: request.body,
				to: recipient,
				attachments: [attachment].compactMap { $0 },
				onFinish: { sent in
					if sent { dismiss() }
				}
			)
		} catch {
			// No mail account, or nothing to present from. Fall back to the user's default mail app
			// — which cannot carry the attachment (RFC 6068), so say so rather than dropping the
			// screenshot silently.
			LoggingPolicy.warning("Mail composer unavailable (\(error)) — falling back to mailto:", logger: .ui)
			mailtoOpened = await EmailController.shared.openMailto(
				subject: request.subject,
				body: request.body,
				to: recipient
			)
			showMailUnavailableNotice = true
		}
	}
}
