//
//  ListItemView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.12.23.
//

import SwiftUI

struct ListItemView: View {
	@ObservedObject var item: DownloadItem

	var body: some View {
		HStack {
			VStack {
				HStack {
					if let fileName = item.url?.lastPathComponent.fileName {
						Text(fileName)
					} else {
						Text("Edit")
							.foregroundColor(.blue)
					}
					Spacer()
				}
				HStack {
					Text(item.state.id)
						.foregroundColor(.gray)
						.font(.caption)
					Spacer()
				}
			}
		}
	}
}
