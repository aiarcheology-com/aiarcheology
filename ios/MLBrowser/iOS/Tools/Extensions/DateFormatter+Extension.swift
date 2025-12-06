//
//  DateFormatter+Extension.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 19.12.23.
//

import Foundation

extension DateFormatter {
	static var longDateFormater: DateFormatter {
		let formater = DateFormatter()
		formater.dateStyle = .long
		return formater
	}
}
