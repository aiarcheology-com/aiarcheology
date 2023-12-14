//
//  HtmlTextView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct HTMLTextView: View {
	let html: String

	var body: some View {
		if let string = attributedString(from: html) {
			Text(string)
		} else {
			Text(html)
		}
	}

	func attributedString(from html: String) -> AttributedString? {
		guard let nsAttributedString = try? NSMutableAttributedString(data: Data(html.utf8),
																	  options: [.documentType: NSAttributedString.DocumentType.html],
																	  documentAttributes: nil) else {
			return nil
		}

		var attrString = try? AttributedString(nsAttributedString, including: \.uiKit)
		attrString?.setAttributes(AttributeContainer([NSAttributedString.Key.foregroundColor : Color.primary]))
		return attrString
	}
}
