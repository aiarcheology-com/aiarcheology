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

	func sendEmail(subject:String, body:String, to:String){
			// Check if the device is able to send emails
		if !MFMailComposeViewController.canSendMail() {
			LoggingPolicy.warning("Device cannot send emails - email composition unavailable", logger: .ui)
			return
		}
			// Create the email composer
		let mailComposer = MFMailComposeViewController()
		mailComposer.mailComposeDelegate = self
		mailComposer.setToRecipients([to])
		mailComposer.setSubject(subject)
		mailComposer.setMessageBody(body, isHTML: false)
		EmailController.getRootViewController()?.present(mailComposer, animated: true, completion: nil)
	}

	func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
		EmailController.getRootViewController()?.dismiss(animated: true, completion: nil)
	}

	static func getRootViewController() -> UIViewController? {
		UIApplication.firstKeyWindow?.rootViewController
	}
}
