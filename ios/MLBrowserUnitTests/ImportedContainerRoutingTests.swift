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

	// MARK: - Routing

	func test_recognisedADAFDetectorFromADirectDownload_isRoutedToConversion() {
		XCTAssertEqual(
			ImportedContainerRouting.route(
				for: .pyTorchZipCheckpoint,
				origin: .directDownload,
				analyser: .adafDetector(className: "Ringfort")
			),
			.convertADAFDetector(className: "Ringfort")
		)
	}

	func test_recognisedADAFDetectorFromFiles_isRoutedToConversion() {
		XCTAssertEqual(
			ImportedContainerRouting.route(
				for: .pyTorchZipCheckpoint,
				origin: .fileImport,
				analyser: .adafDetector(className: nil)
			),
			.convertADAFDetector(className: nil)
		)
	}

	func test_nonADAFCheckpointFromFiles_continuesItsExistingPath() {
		for verdict in [
			ImportedCheckpointVerdict.segmentation,
			.unrecognizedModel(tensorCount: 12),
			.unreadable
		] {
			XCTAssertEqual(
				ImportedContainerRouting.route(
					for: .pyTorchZipCheckpoint,
					origin: .fileImport,
					analyser: verdict
				),
				.continueImport
			)
		}
	}

	func test_directDownloadKeepsItsExistingPermanentAndGenericRejections() {
		let cases: [(ImportedCheckpointVerdict, ImportedContainerRoute)] = [
			(.segmentation, .reject(.segmentationUnsupported)),
			(.unrecognizedModel(tensorCount: 12), .reject(.unrecognizedCheckpoint(tensorCount: 12))),
			(.unreadable, .reject(.unsupportedCheckpoint))
		]
		for (verdict, expected) in cases {
			XCTAssertEqual(
				ImportedContainerRouting.route(
					for: .pyTorchZipCheckpoint,
					origin: .directDownload,
					analyser: verdict
				),
				expected
			)
		}
	}

	func test_realTarFromAnyUntrustedOrigin_isRejectedAsAnArchive() {
		for origin in [ModelAcquisitionSource.directDownload, .fileImport] {
			XCTAssertEqual(
				ImportedContainerRouting.route(
					for: .tarArchive,
					origin: origin,
					analyser: .unreadable
				),
				.reject(.unsupportedArchive),
				"\(origin) must reject a real tar before staging it"
			)
		}
	}

	func test_catalogImportIsNotSniffedOrAnalysed() {
		var sniffs = 0
		var analyses = 0
		let route = ImportedContainerRouting.route(
			for: { sniffs += 1; return .pyTorchZipCheckpoint }(),
			origin: .catalog,
			analyser: { analyses += 1; return .adafDetector(className: "Ringfort") }()
		)
		XCTAssertEqual(route, .continueImport)
		XCTAssertEqual(sniffs, 0)
		XCTAssertEqual(analyses, 0)
	}

	func test_tarAndUnrecognisedContentAreNeverAnalysed() {
		for format in [DownloadedContainerFormat.tarArchive, .unrecognized] {
			var analyses = 0
			_ = ImportedContainerRouting.route(
				for: format,
				origin: .directDownload,
				analyser: { analyses += 1; return .adafDetector(className: "Ringfort") }()
			)
			XCTAssertEqual(analyses, 0, "\(format) must not decode a checkpoint")
		}
	}

	func test_rejectionsCarryALocalizedMessage() {
		XCTAssertEqual(ModelContainerImportError.unsupportedCheckpoint.errorDescription, L10n.Import.unsupportedCheckpoint)
		XCTAssertEqual(ModelContainerImportError.unsupportedArchive.errorDescription, L10n.Import.unsupportedArchive)
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
	/// `standardizedFileURL` strips a leading `/private` only when the stripped path **exists**, so a
	/// standardised return value would diverge from the stored file's own directory on device and
	/// then fail `URL.relativePath(from:)`, which is a lexical path-component test — deleting the
	/// configuration and failing the import.
	///
	/// - Important: the fixture must be a directory that **really exists**, or this test is inert.
	///   Its first version used `/private/var/mobile/…`, which exists on no test host; standardising
	///   it is therefore a no-op, both implementations return the same path, and the test passed
	///   against the very bug it exists to catch. `XCTSkipUnless` below makes that failure mode
	///   impossible to repeat silently: if this host has no directory where the strip fires, the
	///   test reports as skipped rather than as green. Its second version derived the fixture from
	///   `NSTemporaryDirectory()`, which under the simulator is the app's own container and is not
	///   reachable under `/private` — so the strip never fired and the test skipped every run, which
	///   is honest but protects nothing. Hence a candidate list: `DownloadedFileNaming` is pure and
	///   touches no filesystem, so the directory only has to *exist*, never be writable.
	func test_returnedURLKeepsTheStoredDirectoryVerbatim() throws {
		let candidates = ["/private/etc", "/private/var/tmp", "/private/tmp", "/private/var"]
		let privateDirectory = try XCTUnwrap(
			candidates
				.map { URL(fileURLWithPath: $0, isDirectory: true) }
				.first { $0.standardizedFileURL.path != $0.path },
			"""
			None of \(candidates) makes standardizedFileURL strip /private on this host, so the \
			invariant cannot be exercised. Do not delete this test — find a directory that does.
			"""
		)

		let stored = privateDirectory.appendingPathComponent("dl.tmp")
		let url = try XCTUnwrap(DownloadedFileNaming.restoredURL(
			of: stored, namedBy: try XCTUnwrap(URL(string: "https://example.com/model.onnx"))
		))
		XCTAssertEqual(
			url.path,
			privateDirectory.path + "/model.onnx",
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
