//
//  ImportedContainerRoutingTests.swift
//  MLBrowserUnitTests
//
//  AIA-0654.
//

import XCTest
@testable import ML_Browser

/// The guard's job is mostly to *not* fire. These tests pin the combinations that must stay silent
/// as hard as the ones that must reject, because a false rejection breaks an import that works.
final class ImportedContainerRoutingTests: XCTestCase {

	// MARK: - Rejections

	func test_checkpointFromADirectDownload_isRejectedAsACheckpoint() {
		XCTAssertEqual(
			ImportedContainerRouting.rejection(
				for: .pyTorchZipCheckpoint, origin: .directDownload, isCheckpointRoutingEnabled: true
			),
			.unsupportedCheckpoint
		)
	}

	func test_tarFromADirectDownload_isRejectedAsAnArchive() {
		XCTAssertEqual(
			ImportedContainerRouting.rejection(
				for: .tarArchive, origin: .directDownload, isCheckpointRoutingEnabled: true
			),
			.unsupportedArchive
		)
	}

	func test_rejectionsCarryALocalizedMessage() {
		XCTAssertEqual(
			ModelContainerImportError.unsupportedCheckpoint.errorDescription,
			L10n.Import.unsupportedCheckpoint
		)
		XCTAssertEqual(
			ModelContainerImportError.unsupportedArchive.errorDescription,
			L10n.Import.unsupportedArchive
		)
	}

	// MARK: - Everything that must stay silent

	/// The flag is the master switch: off, the whole feature is inert regardless of content.
	func test_flagOff_neverRejectsAnything() {
		for format in [DownloadedContainerFormat.pyTorchZipCheckpoint, .tarArchive, .unrecognized] {
			for origin in [ModelAcquisitionSource.directDownload, .catalog, .fileImport] {
				XCTAssertNil(
					ImportedContainerRouting.rejection(
						for: format, origin: origin, isCheckpointRoutingEnabled: false
					),
					"flag off must be inert for \(format) from \(origin)"
				)
			}
		}
	}

	/// A recognized container that did **not** arrive as a direct download keeps today's behaviour.
	///
	/// Not because other origins cannot produce one — a checkpoint renamed to `.onnx` is selectable
	/// in the Files picker, whose allowed types match by extension — but because of the cost of
	/// rejecting there. A Files import is *copied* into the configuration directory first, and at
	/// the guard's seam there is no Core Data row and no conversion report, so nothing would clean
	/// that copy up: rejecting would trade a cryptic error for a silently orphaned file.
	func test_nonDirectDownloadOrigins_areNeverRejected() {
		for format in [DownloadedContainerFormat.pyTorchZipCheckpoint, .tarArchive] {
			for origin in [ModelAcquisitionSource.catalog, .fileImport] {
				XCTAssertNil(
					ImportedContainerRouting.rejection(
						for: format, origin: origin, isCheckpointRoutingEnabled: true
					),
					"\(format) from \(origin) must keep today's path"
				)
			}
		}
	}

	/// The sniff must not even be evaluated for an import the guard cannot touch — that read is the
	/// only trace this feature could otherwise leave on the catalog and Files paths.
	func test_theContainerIsNotEvenSniffedWhenTheGuardCannotFire() {
		var sniffs = 0
		let counting: () -> DownloadedContainerFormat = {
			sniffs += 1
			return .pyTorchZipCheckpoint
		}

		_ = ImportedContainerRouting.rejection(
			for: counting(), origin: .directDownload, isCheckpointRoutingEnabled: false
		)
		XCTAssertEqual(sniffs, 0, "flag off must not read the file")

		_ = ImportedContainerRouting.rejection(
			for: counting(), origin: .catalog, isCheckpointRoutingEnabled: true
		)
		XCTAssertEqual(sniffs, 0, "a catalog import must not read the file")

		_ = ImportedContainerRouting.rejection(
			for: counting(), origin: .directDownload, isCheckpointRoutingEnabled: true
		)
		XCTAssertEqual(sniffs, 1, "a direct download is the one case that sniffs")
	}

	/// The lock on the ticket's non-regression promise: every format the app imports normally
	/// classifies as `.unrecognized`, and `.unrecognized` is never rejected.
	func test_unrecognizedContent_isNeverRejected() {
		for origin in [ModelAcquisitionSource.directDownload, .catalog, .fileImport] {
			XCTAssertNil(
				ImportedContainerRouting.rejection(
					for: .unrecognized, origin: origin, isCheckpointRoutingEnabled: true
				)
			)
		}
	}

	// MARK: - Origin resolution

	func test_noDownloadURL_isAFileImport() {
		XCTAssertEqual(ModelAcquisitionSource.resolve(downloadURL: nil, catalogSource: nil), .fileImport)
	}

	func test_downloadURLWithoutACatalogSource_isADirectDownload() {
		XCTAssertEqual(
			ModelAcquisitionSource.resolve(downloadURL: URL(string: "https://example.com/m.onnx"), catalogSource: nil),
			.directDownload
		)
	}

	/// The assertion that keeps the guard away from catalog installs. A catalog install has **both**
	/// a download URL and a catalog source; reading the URL first would call it a direct download,
	/// and the guard would then start inspecting — and could reject — catalog artifacts.
	func test_catalogSourceWins_evenWithADownloadURL() {
		XCTAssertEqual(
			ModelAcquisitionSource.resolve(
				downloadURL: URL(string: "https://huggingface.co/x/resolve/main/m.mlmodel"),
				catalogSource: "huggingface"
			),
			.catalog
		)
	}

	// MARK: - Naming a download after its URL (the traversal guard)

	private let stored = URL(fileURLWithPath: "/Documents/Configurations/ABC/CFNetworkDownload_x1.tmp")

	func test_ordinaryFilename_isRestored() throws {
		let url = try XCTUnwrap(DownloadedFileNaming.restoredURL(
			of: stored, namedBy: try XCTUnwrap(URL(string: "https://example.com/MobileNetV2.onnx"))
		))
		XCTAssertEqual(url.lastPathComponent, "MobileNetV2.onnx")
	}

	/// A query string is not part of the path, so the Zenodo form must name the file correctly.
	func test_queryStringNeverReachesTheFilename() throws {
		let url = try XCTUnwrap(DownloadedFileNaming.restoredURL(
			of: stored,
			namedBy: try XCTUnwrap(URL(string: "https://zenodo.org/records/15848663/files/OD_ringfort.onnx?download=1"))
		))
		XCTAssertEqual(url.lastPathComponent, "OD_ringfort.onnx")
	}

	/// The measured payload: `lastPathComponent` percent-decodes, so this arrives as the single
	/// component "../../escape.onnx", whose `pathExtension` is `onnx`. Appended unchecked it
	/// resolves two directories above the configuration, where the caller would delete an existing
	/// file before moving onto it.
	func test_percentEncodedTraversal_isRefused() throws {
		let hostile = try XCTUnwrap(URL(string: "https://example.com/..%2F..%2Fescape.onnx"))
		XCTAssertEqual(hostile.lastPathComponent, "../../escape.onnx", "precondition: Foundation decodes %2F")
		XCTAssertNil(DownloadedFileNaming.restoredURL(of: stored, namedBy: hostile))
	}

	func test_lowercasePercentEncodedTraversal_isRefused() throws {
		XCTAssertNil(DownloadedFileNaming.restoredURL(
			of: stored, namedBy: try XCTUnwrap(URL(string: "https://example.com/%2e%2e%2f%2e%2e%2fescape.onnx"))
		))
	}

	func test_singleEncodedSeparator_isRefused() throws {
		XCTAssertNil(DownloadedFileNaming.restoredURL(
			of: stored, namedBy: try XCTUnwrap(URL(string: "https://example.com/sub%2Fmodel.onnx"))
		))
	}

	func test_rootURLWithNoFilename_isRefused() throws {
		XCTAssertNil(DownloadedFileNaming.restoredURL(
			of: stored, namedBy: try XCTUnwrap(URL(string: "https://example.com/"))
		))
	}

	/// An unencoded `../` is resolved away by Foundation before `lastPathComponent` sees it, so this
	/// is already benign — pinned so a future "simplification" of the guard cannot make it unsafe.
	func test_plainDotDotSegments_resolveToAnOrdinaryName() throws {
		let url = try XCTUnwrap(DownloadedFileNaming.restoredURL(
			of: stored, namedBy: try XCTUnwrap(URL(string: "https://example.com/dir/../../model.onnx"))
		))
		XCTAssertEqual(url.lastPathComponent, "model.onnx")
	}

	/// The check that catches a standardised path leaking out of the naming decision.
	///
	/// `standardizedFileURL` strips a leading `/private` only when the stripped path exists, so a
	/// standardised return value would diverge from the stored file's own directory on device and
	/// fail `URL.relativePath(from:)`, which is a raw string prefix test. This assertion fails in
	/// the simulator too, which is the point: the device-only variant of this bug is invisible here.
	func test_returnedURLKeepsTheStoredDirectoryVerbatim() throws {
		let privatePrefixed = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Configurations/ABC/dl.tmp")
		let url = try XCTUnwrap(DownloadedFileNaming.restoredURL(
			of: privatePrefixed, namedBy: try XCTUnwrap(URL(string: "https://example.com/model.onnx"))
		))
		XCTAssertEqual(
			url.path,
			privatePrefixed.deletingLastPathComponent().path + "/model.onnx",
			"the returned URL must be derived from the unstandardised stored directory"
		)
	}

	func test_nameMatchingTheStoredFile_isNotAPointlessRename() throws {
		XCTAssertNil(DownloadedFileNaming.restoredURL(
			of: URL(fileURLWithPath: "/Documents/Configurations/ABC/model.onnx"),
			namedBy: try XCTUnwrap(URL(string: "https://example.com/model.onnx"))
		))
	}
}
