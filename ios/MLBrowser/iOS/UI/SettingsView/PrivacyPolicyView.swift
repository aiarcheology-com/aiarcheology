//
//  PrivacyPolicyView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

struct PrivacyPolicyView: View {
	var htmlFileName: String

	var body: some View {
		ScrollView {
			if let url = Bundle.main.url(forResource: htmlFileName, withExtension: "html"),
			   let htmlContent = try? String(contentsOf: url) {
				HTMLTextView(html: htmlContent)
					.padding()
			} else {
				Text(L10n.About.privacyNotAvailable)
			}
		}
	}
}
