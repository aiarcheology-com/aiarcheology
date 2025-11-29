import XCTest
import UniformTypeIdentifiers
@testable import ML_Browser

@MainActor
final class ModelAcquisitionCoordinatorTests: XCTestCase {

	func testBeginLocalImport_setsFlag() {
		let types: [UTType] = []
		let coordinator = ModelAcquisitionCoordinator(allowedTypes: types)
		XCTAssertFalse(coordinator.isShowingFileImporter)
		coordinator.beginLocalImport()
		XCTAssertTrue(coordinator.isShowingFileImporter)
	}
	
	func testBeginRemoteImport_setsFlag() {
		let types: [UTType] = []
		let coordinator = ModelAcquisitionCoordinator(allowedTypes: types)
		XCTAssertFalse(coordinator.isShowingDownloader)
		coordinator.beginRemoteImport()
		XCTAssertTrue(coordinator.isShowingDownloader)
	}
	
	func testCompleteLocalImport_setsPendingImport() {
		let types: [UTType] = []
		let coordinator = ModelAcquisitionCoordinator(allowedTypes: types)
		let url = URL(fileURLWithPath: "/tmp/test.mlmodel")
		struct DummyProvider: ModelProvider {
			func result(_ error: ModelProviderError, id: UUID) { }
		}
		XCTAssertNil(coordinator.pendingImport)
		coordinator.completeLocalImport(url: url, provider: DummyProvider())
		XCTAssertNotNil(coordinator.pendingImport)
	}
	
	func testMarkImportHandled_clearsPendingImport() {
		let types: [UTType] = []
		let coordinator = ModelAcquisitionCoordinator(allowedTypes: types)
		let url = URL(fileURLWithPath: "/tmp/test.mlmodel")
		struct DummyProvider: ModelProvider {
			func result(_ error: ModelProviderError, id: UUID) { }
		}
		coordinator.completeLocalImport(url: url, provider: DummyProvider())
		XCTAssertNotNil(coordinator.pendingImport)
		coordinator.markImportHandled()
		XCTAssertNil(coordinator.pendingImport)
	}
}
