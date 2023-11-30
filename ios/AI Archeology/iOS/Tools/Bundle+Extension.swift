//
//  Bundle+Extension.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 30.11.23.
//

import Foundation

extension Bundle {
	var iconFileName: String? {
		guard let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
			  let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
			  let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
			  let iconFileName = iconFiles.last
		else { return nil }
		return iconFileName
	}
}
