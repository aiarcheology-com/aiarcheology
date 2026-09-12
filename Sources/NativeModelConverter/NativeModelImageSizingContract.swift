//
//  NativeModelImageSizingContract.swift
//  NativeModelConverter
//
//  A versioned host-input contract carried by converted detector artifacts.
//

import Foundation

/// The host-side image-sizing transform a converted model requires before Vision receives a frame.
///
/// Core ML's image constraint exposes only the final input canvas. It cannot describe the resize
/// rule that produced its content, so a runtime must not infer this fact from a filename, producer,
/// or input shape. A converted model that needs a pre-sized image instead carries this complete,
/// versioned contract in its outer `creatorDefined` metadata.
public struct NativeModelImageSizingContract: Codable, Equatable, Sendable {

	public static let formatIdentifier = "com.aiarcheology.native-model-image-sizing"
	public static let currentFormatVersion = 1
	public static let userDefinedKey = "com.aiarcheology.native.target.image-sizing.json"

	public enum TransformProfile: String, Codable, Sendable {
		/// torchvision `GeneralizedRCNNTransform`: min/max aspect-preserving resize, Float64 floor
		/// rounding, align-corners-false bilinear sampling, then a fixed top-left canvas.
		case torchvisionGeneralizedRCNN = "torchvision-generalized-rcnn-v1"
	}

	public enum ContentPlacement: String, Codable, Sendable {
		/// Content begins at the raster top-left; padding occupies only the right and bottom edges.
		case topLeft = "top-left"
	}

	public enum PaddingFill: String, Codable, Sendable {
		/// Padding is the ImageNet mean in the 8-bit image handed to Core ML, which becomes exactly
		/// zero after the model's emitted ImageNet normalisation layer.
		case normalizedZero = "normalized-zero"
	}

	/// All fields are part of the wire contract. The names are deliberately verbose: this JSON is
	/// read by a runtime from an artifact, not merely by source code that happens to share constants.
	public let format: String
	public let formatVersion: Int
	public let transformProfile: TransformProfile
	public let minSize: Int
	public let maxSize: Int
	public let canvasWidth: Int
	public let canvasHeight: Int
	public let contentPlacement: ContentPlacement
	public let paddingFill: PaddingFill

	public init(
		minSize: Int,
		maxSize: Int,
		canvas: NativeModelImageSize,
		transformProfile: TransformProfile = .torchvisionGeneralizedRCNN,
		contentPlacement: ContentPlacement = .topLeft,
		paddingFill: PaddingFill = .normalizedZero
	) {
		format = Self.formatIdentifier
		formatVersion = Self.currentFormatVersion
		self.transformProfile = transformProfile
		self.minSize = minSize
		self.maxSize = maxSize
		canvasWidth = canvas.width
		canvasHeight = canvas.height
		self.contentPlacement = contentPlacement
		self.paddingFill = paddingFill
	}

	/// The contract recorded for the closed ADAF Faster R-CNN registry. Future pre-sized models may
	/// carry a different valid instance; consumers route on the contract itself, never this name.
	public static let adafFasterRCNN = Self(
		minSize: 800,
		maxSize: 1_333,
		canvas: NativeModelImageSize(width: 1_344, height: 1_344)
	)

	public var canvas: NativeModelImageSize {
		NativeModelImageSize(width: canvasWidth, height: canvasHeight)
	}

	/// Decodes only a complete contract this runtime understands. An absent, malformed, or newer
	/// contract intentionally returns `nil`, so a caller keeps its established generic image path.
	public init?(userDefined: [String: String]) {
		guard let encoded = userDefined[Self.userDefinedKey],
			let decoded = try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8)),
			decoded.isSupported
		else {
			return nil
		}
		self = decoded
	}

	/// Canonical JSON makes an app-vs-CLI artifact comparison stable while keeping this metadata as
	/// one atomically validated fact instead of a group of optional strings.
	public func canonicalJSON() throws -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		let data = try encoder.encode(self)
		guard let encoded = String(bytes: data, encoding: .utf8) else {
			throw NativeModelCoreMLEmissionError.invalidOperation(
				operation: "imageSizingContract",
				reason: "The JSON encoder produced non-UTF-8 data."
			)
		}
		return encoded
	}

	private var isSupported: Bool {
		format == Self.formatIdentifier &&
			formatVersion == Self.currentFormatVersion &&
			minSize > 0 &&
			maxSize >= minSize &&
			canvasWidth >= maxSize &&
			canvasHeight >= maxSize &&
			canvas.isEmpty == false
	}
}
