//
//  ONNXModelZooCatalogProvider.swift
//  AI Archeology
//
//  AIA-0497: curated, oracle-verified ONNX sources converted to Core ML on-device at import.
//

import Foundation

/// Builds the resolve URLs for the verified-ONNX catalog. These are public files served over plain
/// HTTPS (GitHub's `raw` redirect and the Hugging Face `resolve` view) that download via an ordinary
/// HTTP redirect, not the Xet-backed transfer used for Hub packages, so no `xetFile` metadata is
/// attached. The literals are enumerated by `ONNXModelZooCatalogProvider.verifiedEntries` in a unit
/// test, so a malformed literal fails there rather than reaching a device.
private enum VerifiedONNXCatalogURLs {
	static func resolve(_ absoluteString: String) -> URL {
		URL(string: absoluteString) ?? URL(fileURLWithPath: "/")
	}
}

/// A curated set of ONNX models whose on-device Core ML conversion is verified against an independent
/// oracle (`Tests/NativeModelConverterTests/Fixtures/ONNXConversionModels.json`). Unlike the live
/// Hugging Face search, every entry here is reviewed: the classifiers and Tiny YOLOv2 import with real
/// class labels (`.verifiedConvertible`), while the metadata-less YOLO exports import with generic
/// `class_<i>` labels but verified box geometry (`.verifiedGeometryGenericLabels`). The family tag is
/// display/filter-only and never influences labels, preprocessing, or task (AIA-0497).
actor ONNXModelZooCatalogProvider: CatalogProvider {
	nonisolated let descriptor = CatalogProviderDescriptor(id: "onnx-verified", displayName: "Verified ONNX")

	private static let manifest = CuratedCatalogManifest(
		providerID: "onnx-verified",
		entries: [
			.init(
				id: "onnx-mobilenetv2-10",
				providerID: "onnx-verified",
				displayName: "MobileNetV2 (ONNX)",
				author: "ONNX Model Zoo",
				task: .imageClassification,
				sizeBytes: 14_000_000,
				artifactURL: VerifiedONNXCatalogURLs.resolve(
					"https://github.com/onnx/models/raw/main/validated/vision/classification/mobilenet/model/mobilenetv2-10.onnx"
				),
				artifactFilename: "mobilenetv2-10.onnx",
				family: .mobileNetV2,
				format: .onnx,
				support: .verifiedConvertible,
				keywords: ["mobilenet", "mobilenetv2", "onnx", "imagenet", "image", "classification"]
			),
			.init(
				id: "onnx-resnet50-v1-7",
				providerID: "onnx-verified",
				displayName: "ResNet-50 (ONNX)",
				author: "ONNX Model Zoo",
				task: .imageClassification,
				sizeBytes: 98_000_000,
				artifactURL: VerifiedONNXCatalogURLs.resolve(
					"https://github.com/onnx/models/raw/main/validated/vision/classification/resnet/model/resnet50-v1-7.onnx"
				),
				artifactFilename: "resnet50-v1-7.onnx",
				family: .resNet50,
				format: .onnx,
				support: .verifiedConvertible,
				keywords: ["resnet", "resnet50", "onnx", "imagenet", "image", "classification"]
			),
			.init(
				id: "onnx-squeezenet1.0-12",
				providerID: "onnx-verified",
				displayName: "SqueezeNet (ONNX)",
				author: "ONNX Model Zoo",
				task: .imageClassification,
				sizeBytes: 5_000_000,
				artifactURL: VerifiedONNXCatalogURLs.resolve(
					"https://github.com/onnx/models/raw/main/validated/vision/classification/squeezenet/model/squeezenet1.0-12.onnx"
				),
				artifactFilename: "squeezenet1.0-12.onnx",
				family: .squeezeNet,
				format: .onnx,
				support: .verifiedConvertible,
				keywords: ["squeezenet", "onnx", "imagenet", "image", "classification"]
			),
			.init(
				id: "onnx-tinyyolov2-8",
				providerID: "onnx-verified",
				displayName: "Tiny YOLOv2 (ONNX)",
				author: "ONNX Model Zoo",
				task: .objectDetection,
				sizeBytes: 61_000_000,
				artifactURL: VerifiedONNXCatalogURLs.resolve(
					"https://github.com/onnx/models/raw/main/validated/vision/object_detection_segmentation/tiny-yolov2/model/tinyyolov2-8.onnx"
				),
				artifactFilename: "tinyyolov2-8.onnx",
				family: .yolo,
				format: .onnx,
				support: .verifiedConvertible,
				keywords: ["yolo", "tinyyolo", "tiny", "onnx", "object", "detection", "voc"]
			),
			.init(
				id: "onnx-yolov8n-s1777",
				providerID: "onnx-verified",
				displayName: "YOLOv8n (ONNX)",
				author: "s1777",
				task: .objectDetection,
				sizeBytes: 12_000_000,
				artifactURL: VerifiedONNXCatalogURLs.resolve(
					"https://huggingface.co/s1777/yolo-v8n-onnx/resolve/main/yolov8n.onnx"
				),
				artifactFilename: "yolov8n.onnx",
				family: .yolo,
				format: .onnx,
				support: .verifiedGeometryGenericLabels,
				keywords: ["yolo", "yolov8", "yolov8n", "onnx", "object", "detection", "coco"]
			),
			.init(
				id: "onnx-yolo11n-aaurelions",
				providerID: "onnx-verified",
				displayName: "YOLO11n (ONNX)",
				author: "aaurelions",
				task: .objectDetection,
				sizeBytes: 11_000_000,
				artifactURL: VerifiedONNXCatalogURLs.resolve(
					"https://huggingface.co/aaurelions/yolo11n.onnx/resolve/f46d9b72aa9a0f02bc00484446e2310b1a549bce/yolo11n.onnx"
				),
				artifactFilename: "yolo11n.onnx",
				family: .yolo,
				format: .onnx,
				support: .verifiedGeometryGenericLabels,
				keywords: ["yolo", "yolo11", "yolo11n", "onnx", "object", "detection", "coco"]
			)
		]
	)

	/// The catalog models this provider serves, exposed for test enumeration. A curated manifest only
	/// matches real query terms, so `search("")` returns nothing; this seam lets tests assert the full
	/// set without relaxing search semantics. Derived from `manifest`, so there is one source of truth.
	static let verifiedEntries: [CatalogModel] = manifest.entries.map(\.model)

	func search(query: String) async throws -> [CatalogModel] {
		Self.manifest.search(query: query)
	}

	func resolveFiles(for model: CatalogModel) async throws -> [CatalogFile] {
		try Self.manifest.resolveFiles(for: model)
	}
}
