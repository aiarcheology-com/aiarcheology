//
//  Int+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.12.23.
//

import Foundation

extension Int {
	func formatBytesAsHumanReadable() -> String {
		let byteCountFormatter = ByteCountFormatter()
		byteCountFormatter.allowedUnits = [.useMB, .useGB] // Only show MB and GB
		byteCountFormatter.countStyle = .file
		byteCountFormatter.includesUnit = true
		byteCountFormatter.includesCount = true
		byteCountFormatter.isAdaptive = true
		byteCountFormatter.zeroPadsFractionDigits = true

		return byteCountFormatter.string(fromByteCount: Int64(self))
	}
}
