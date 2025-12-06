//
//  UIApplication+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 04.12.23.
//

import UIKit

extension UIApplication {
	static var firstKeyWindow: UIWindow? {
		return UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.filter { $0.activationState == .foregroundActive }
			.first?.keyWindow

	}
}
