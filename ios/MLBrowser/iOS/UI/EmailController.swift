//
//  EmailController.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 04.12.23.
//

import Foundation
import MessageUI
import OSLog

@MainActor
final class EmailController: NSObject, @MainActor MFMailComposeViewControllerDelegate {
	public static let shared = EmailController()
	private override init() { }

	/// An attachment the **user** chose to include (AIA-0454): either a photo picked from their
	/// library or a redacted/unredacted application-log tail expressly enabled in the support form.
	struct Attachment {
		let data: Data
		let mimeType: String
		let fileName: String
	}

	/// Why the composer could not be shown. Callers must handle this rather than leaving a
	/// button that silently does nothing — `canSendMail()` is false whenever Mail.app is
	/// removed or no account is configured, which is common in production, not an edge case.
	enum ComposerUnavailable: Error {
		/// No mail account is configured on the device.
		case mailNotConfigured
		/// No view controller was available to present from.
		case noPresenter
	}

	/// Fires after the composer is fully dismissed. `sent` is true when the user handed the
	/// message to Mail (queued for delivery — not proof it left the device). One composer can be
	/// up at a time, so a single stored callback suffices; it is cleared before it runs.
	private var onComposerFinish: ((_ sent: Bool) -> Void)?

	/// Presents the system mail composer.
	///
	/// Throws instead of returning silently: the previous version logged a warning and
	/// returned, so on a device without Mail the support button did nothing at all and read
	/// as a broken app. Callers use the thrown reason to fall back (AIA-0454).
	///
	/// Presents from the **topmost** presented view controller, not the root: callers are
	/// typically sheets, and UIKit refuses a presentation from a view controller that is already
	/// presenting — the composer would silently never appear.
	func sendEmail(
		subject: String,
		body: String,
		to: String,
		attachments: [Attachment] = [],
		onFinish: ((_ sent: Bool) -> Void)? = nil
	) throws {
		guard MFMailComposeViewController.canSendMail() else {
			LoggingPolicy.warning("Device cannot send emails - email composition unavailable", logger: .ui)
			throw ComposerUnavailable.mailNotConfigured
		}
		guard let presenter = EmailController.topmostViewController() else {
			LoggingPolicy.warning("No view controller to present the mail composer from", logger: .ui)
			throw ComposerUnavailable.noPresenter
		}
			// Create the email composer
		let mailComposer = MFMailComposeViewController()
		mailComposer.mailComposeDelegate = self
		mailComposer.setToRecipients([to])
		mailComposer.setSubject(subject)
		mailComposer.setMessageBody(body, isHTML: false)
		for attachment in attachments {
			mailComposer.addAttachmentData(attachment.data, mimeType: attachment.mimeType, fileName: attachment.fileName)
		}
		onComposerFinish = onFinish
		presenter.present(mailComposer, animated: true, completion: nil)
	}

	func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
		// Dismiss the controller we were handed, not a freshly looked-up root: `firstKeyWindow`
		// resolves the first foreground scene, which is not necessarily the scene presenting this
		// composer. On Mac/iPad multi-window that dismissed the wrong view controller.
		controller.dismiss(animated: true) { [self] in
			let callback = onComposerFinish
			onComposerFinish = nil
			callback?(result == .sent)
		}
	}

	/// Opens the user's default mail app via a `mailto:` URL.
	///
	/// The last-resort tier when `sendEmail` reports `.mailNotConfigured`: honours whatever mail
	/// app the user has set as default (iOS 14+), which `MFMailComposeViewController` does not.
	/// **Cannot carry attachments** — `mailto:` has no such field (RFC 6068) — so callers must tell
	/// the user their attachments did not come along.
	@discardableResult
	func openMailto(subject: String, body: String, to recipient: String) async -> Bool {
		// URLComponents applies query-component encoding; `.urlPathAllowed` would leave `&` and `=`
		// intact and corrupt the link.
		var components = URLComponents()
		components.scheme = "mailto"
		components.path = recipient
		components.queryItems = [
			URLQueryItem(name: "subject", value: subject),
			URLQueryItem(name: "body", value: body)
		]
		guard let url = components.url, UIApplication.shared.canOpenURL(url) else {
			LoggingPolicy.warning("No mail app available for a mailto: fallback", logger: .ui)
			return false
		}
		return await UIApplication.shared.open(url)
	}

	/// The view controller a new presentation must start from: the far end of the *key* window's
	/// `presentedViewController` chain. Presenting from the root while a sheet is up is a silent
	/// no-op — UIKit logs "already presenting" and drops it.
	///
	/// Resolves the genuinely key window rather than `UIApplication.firstKeyWindow`, whose
	/// `connectedScenes.first { $0.activationState == .foregroundActive }` picks an **arbitrary**
	/// scene when several are foreground-active — `connectedScenes` is a Set. On iPad Split View
	/// and Mac multi-window that is a coin flip, and losing it presents into a hierarchy the user
	/// is not looking at. Falls back to any foreground-active scene for the case where no window
	/// claims key (e.g. an already-presented system sheet holds it).
	static func topmostViewController() -> UIViewController? {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
			?? scenes.first { $0.activationState == .foregroundActive }?.keyWindow
		guard var top = window?.rootViewController else { return nil }
		while let presented = top.presentedViewController {
			top = presented
		}
		return top
	}
}
