import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Coordinates acquisition of Core ML models from either local file import or remote download.
@MainActor
final class ModelAcquisitionCoordinator: ObservableObject {
	// Routing / presentation state
	@Published var isShowingDownloader: Bool = false
	@Published var isShowingFileImporter: Bool = false
	
	/// When a flow finishes resolving a URL + ID + provider, it is delivered here once.
	@Published private(set) var pendingImport: ImportRequest?
	
	/// Content types allowed by the file importer.
	let allowedTypes: [UTType]
	
	init(allowedTypes: [UTType]) {
		self.allowedTypes = allowedTypes
	}
	
	struct ImportRequest: Equatable, Identifiable {
		let id = UUID()
		let url: URL
		let configurationId: UUID
		let provider: ModelProvider
		
		static func == (lhs: ImportRequest, rhs: ImportRequest) -> Bool {
			lhs.id == rhs.id
		}
	}
	
	func beginLocalImport() {
		isShowingFileImporter = true
	}
	
	func beginRemoteImport() {
		isShowingDownloader = true
	}
	
	/// Called by the UI when a file importer completes successfully.
	func completeLocalImport(url: URL, provider: ModelProvider) {
		let configId = UUID()
		pendingImport = ImportRequest(url: url, configurationId: configId, provider: provider)
	}
	
	/// Called by the downloader flow when the user taps Import in `DownloadDetailView`.
	func completeRemoteImport(url: URL, configurationId: UUID, provider: ModelProvider) {
		pendingImport = ImportRequest(url: url, configurationId: configurationId, provider: provider)
	}
	
	/// Mark the current pending import as handled so observers don't process it twice.
	func markImportHandled() {
		pendingImport = nil
	}
}
