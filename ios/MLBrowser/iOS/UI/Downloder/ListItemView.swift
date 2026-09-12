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

    private let entityId: UUID

    init(item: DownloadItem) {
        self.item = item
        self.entityId = item.entityId
    }

	var body: some View {
		HStack {
			VStack {
				HStack {
					if let fileName = item.url?.lastPathComponent.fileName {
						Text(fileName)
							.testability(Testability.Label.listItemFileName)
					} else {
						Text(L10n.Common.edit)
							.testability(Testability.Label.listItemFileName)
							.foregroundColor(.blue)
					}
					Spacer()
				}
				HStack {
					Text(item.state.localizedName)
						.testability(Testability.Label.listItemState)
						.foregroundColor(.gray)
						.font(.caption)
					Spacer()
				}
				if progressValue > 0.0 {
					ProgressView(value: progressValue)
						.testability(Testability.ProgressView.listItemProgress)
						.progressViewStyle(LinearProgressViewStyle(tint: .green))
						.frame(height: 5)
				}
			}
			.onReceive(download.progressPublisher(for: entityId)) { newProgress in
				progress = newProgress
			}
		}
	}

	/// Returns the appropriate progress value based on download state:
	/// - Complete/Imported: 1.0
	/// - Downloading: live progress from publisher
	/// - Paused/Other: persisted progress from CoreData
	private var progressValue: Double {
		switch item.state {
		case .complete, .imported:
			return 1.0
		case .downloading:
			return progress
		default:
			return item.progress
		}
	}
}
