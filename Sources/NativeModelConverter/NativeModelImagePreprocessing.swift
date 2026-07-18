//
//  NativeModelImagePreprocessing.swift
//  NativeModelConverter
//

/// Per-channel affine preprocessing applied to an image classifier's pixel input.
///
/// Core ML presents an image input to a neural network as raw pixels in `[0, 255]`. Image
/// classifiers trained in PyTorch/ONNX expect a normalized tensor instead, so the emitter prepends a
/// scale layer computing `output[c] = scale[c] * pixel[c] + bias[c]` per channel. A single scalar
/// scale (Core ML's built-in image scaler) cannot express ImageNet normalization, whose standard
/// deviation differs per channel — hence a full per-channel affine.
public struct NativeModelImagePreprocessing: Sendable, Equatable {
	public enum ColorSpace: Sendable, Equatable {
		case grayscale
		case rgb
		case bgr

		var channelCount: Int { self == .grayscale ? 1 : 3 }

		/// Core ML `ImageFeatureType.ColorSpace` enum value.
		var coreMLValue: UInt64 {
			switch self {
			case .grayscale: 10
			case .rgb: 20
			case .bgr: 30
			}
		}
	}

	public let colorSpace: ColorSpace
	/// Per-channel multiplier applied to `[0, 255]` pixels, in the channel order of `colorSpace`.
	public let scale: [Float]
	/// Per-channel bias added after scaling, in the channel order of `colorSpace`.
	public let bias: [Float]

	public init(colorSpace: ColorSpace, scale: [Float], bias: [Float]) {
		self.colorSpace = colorSpace
		self.scale = scale
		self.bias = bias
	}

	var channelCount: Int { colorSpace.channelCount }

	/// Standard ImageNet RGB normalization: `(pixel / 255 - mean) / std` with
	/// `mean = [0.485, 0.456, 0.406]` and `std = [0.229, 0.224, 0.225]`. This is the convention used
	/// by torchvision and the ONNX Model Zoo image classifiers, expanded into the equivalent affine
	/// `scale = 1 / (255 · std)`, `bias = -mean / std`.
	public static let imageNetRGB: NativeModelImagePreprocessing = {
		let mean: [Float] = [0.485, 0.456, 0.406]
		let std: [Float] = [0.229, 0.224, 0.225]
		return NativeModelImagePreprocessing(
			colorSpace: .rgb,
			scale: std.map { 1 / (255 * $0) },
			bias: zip(mean, std).map { -$0 / $1 }
		)
	}()
}
