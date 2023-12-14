//
//  NumberFormater.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import Foundation

extension NumberFormatter {
	static var historyLimitFormatter: NumberFormatter {
		let formatter = NumberFormatter()
		formatter.numberStyle = .none
		formatter.minimum = 0
		formatter.maximum = 100
		return formatter
	}
}
