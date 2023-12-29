//
//  ListItemView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 27.12.23.
//

import SwiftUI

struct ListItemView: View {
	@EnvironmentObject var download: Downloader
	@ObservedObject var item: DownloadItem
	@State private var progress: Double = 0.0

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
				if progress > 0.0 {
					ProgressView(value: [.complete, .imported].contains(item.state) ? 1.0 : progress)
						.progressViewStyle(LinearProgressViewStyle(tint: .green))
						.frame(height: 5)
				}
			}
			.onReceive(download.progressPublisher(for: item.entityId)) { newProgress in // Core data properties are optional
				progress = newProgress
			}
		}
	}
}
