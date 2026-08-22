//
//  NativeModelImageSizing.swift
//  NativeModelConverter
//

import Foundation

/// An integer pixel size. Foundation-only on purpose: this package has never imported CoreGraphics
/// (`Sources/` contains no `CGRect`, `CGFloat` or `import CoreGraphics`), and two command-line
/// executables link it. Conversion to `CGRect` happens at the app boundary.
public struct NativeModelImageSize: Equatable, Sendable {
	public let width: Int
	public let height: Int

	public init(width: Int, height: Int) {
		self.width = width
		self.height = height
	}

	public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// A rectangle in Vision's convention: the unit square, **origin bottom-left**.
///
/// Named after the convention rather than after a use, because the bottom-left origin is the single
/// most common way a box ends up displaced by exactly the height of its padding.
public struct NativeModelNormalizedRect: Equatable, Sendable {
	public let x: Double
	public let y: Double
	public let width: Double
	public let height: Double

	public init(x: Double, y: Double, width: Double, height: Double) {
		self.x = x
		self.y = y
		self.width = width
		self.height = height
	}

	public static let unit = NativeModelNormalizedRect(x: 0, y: 0, width: 1, height: 1)
}

/// A rectangle in raster convention: integer pixels, **origin top-left**. What a crop actually is.
public struct NativeModelPixelRect: Equatable, Sendable {
	public let x: Int
	public let y: Int
	public let width: Int
	public let height: Int

	public init(x: Int, y: Int, width: Int, height: Int) {
		self.x = x
		self.y = y
		self.width = width
		self.height = height
	}
}

/// Sizes an image the way `torchvision.models.detection.transform.GeneralizedRCNNTransform` does, and
/// maps detected boxes back out again (AIA-0680).
///
/// M3a measured that no Core ML NN-spec resize mode reproduces that transform's bilinear
/// (`align_corners=False`) — the closest leaves 0.1296 absolute on `[0, 1]` data — and that pinning
/// `min_size` to the tile size is not a workaround but a different model, moving boxes 19.43 px. So
/// the resize cannot live in the emitted graph, and this is where it lives instead.
///
/// Every rule below was read out of torchvision 0.23.0 rather than recalled, and the figures the
/// tests assert against were produced by *calling* that transform
/// (`scripts/generate_torchvision_resize_oracle.py`), not by re-deriving it:
///
/// - **Sizing** (`transform.py:60`) — `scale = min(minSize / shortSide, maxSize / longSide)`. The
///   short side reaches `minSize` only when the long side has not hit `maxSize` first; for a third of
///   a portrait phone snapshot (aspect ≈ 2.17) it is `maxSize` that binds, and the short side lands
///   well below `minSize`.
/// - **Rounding** (`functional.py`, `recompute_scale_factor=True`) — the output size is
///   `floor(sourceDimension · scale)` per axis, and the resampler then re-derives its ratios from
///   those integers. The horizontal and vertical ratios therefore **differ** whenever the floor
///   rounds differently: 769×512 resizes to 1201×800, which is 1.561769 across and 1.5625 down.
///   `Geometry` has no single `scale` field for exactly that reason.
/// - **Padding** (`transform.py:243-253`) — the canvas is each dimension rounded up to a multiple of
///   32 and the content is copied into `[..., :height, :width]` of a zero tensor. Origin top-left,
///   padding on the **right and bottom only**. It is not a centred letterbox, and a centred
///   implementation would still pass a round-trip test while feeding the network a displaced image.
/// - **The inverse** (`transform.py:306-319`, `resize_boxes`) — `x · (sourceWidth / resizedWidth)`
///   and `y · (sourceHeight / resizedHeight)`, per axis, from the integer sizes. This type mirrors
///   that call rather than inventing an inverse.
///
/// Normalisation deliberately stays in the emitted graph
/// (`NativeModelImagePreprocessing.imageNetRGB`) — see `NATIVE_MODEL_CONVERSION.md`. That is forced,
/// not preferred: a Vision detector interface requires an image input, and Core ML image inputs are
/// 8-bit, so there is no float buffer app-side normalisation could be handed to.
public enum NativeModelImageSizing {

	// MARK: - Geometry

	/// What one sizing operation did, in integers, so the inverse can be derived from the same
	/// numbers the forward pass used rather than recomputed from a scale that may have rounded
	/// differently.
	public struct Geometry: Equatable, Sendable {
		/// The crop handed in, in pixels.
		public let sourceSize: NativeModelImageSize
		/// `floor(sourceDimension · scale)` per axis — the content, before padding.
		public let resizedSize: NativeModelImageSize
		/// The padded model input. Content sits at the top-left corner of it.
		public let canvasSize: NativeModelImageSize

		public init(
			sourceSize: NativeModelImageSize,
			resizedSize: NativeModelImageSize,
			canvasSize: NativeModelImageSize
		) {
			self.sourceSize = sourceSize
			self.resizedSize = resizedSize
			self.canvasSize = canvasSize
		}

		public var padRight: Int { canvasSize.width - resizedSize.width }
		public var padBottom: Int { canvasSize.height - resizedSize.height }

		/// Derived, never stored. A stored scalar scale is the bug this type exists to make
		/// unrepresentable.
		public var scaleX: Double { Double(resizedSize.width) / Double(sourceSize.width) }
		public var scaleY: Double { Double(resizedSize.height) / Double(sourceSize.height) }

		/// True when the two axes resized by different ratios — the ordinary case for a non-square
		/// input, and the case a single-scale implementation gets wrong.
		public var hasPerAxisScale: Bool { scaleX != scaleY }
	}

	/// The transform's target size for a source image.
	///
	/// **The precision and the evaluation order are both load-bearing.** `F.interpolate` has two
	/// output-size rules, and only one of them runs here: the float32 branch at
	/// `torch/nn/functional.py:4698-4710` is guarded by `torch._C._get_tracing_state()`, so the eager
	/// path a detector actually takes is `_sym_int(size · scaleFactor)` at `:4717` — a Python
	/// `int × float` product, i.e. **float64**, truncated. So the scale is computed once in `Double`
	/// and multiplied in `Double`; narrowing to `Float`, or folding the division into the multiply,
	/// moves the result by a whole pixel on the knife-edge cases.
	///
	/// Those cases are real, not hypothetical. 646×1077 binds on `maxSize`, yet `1077 · (1333/1077)`
	/// evaluates just below 1333, so the long side lands on **1332** and the short side on **799** —
	/// one pixel short on both axes. The committed oracle carries that case for exactly this reason.
	public static func resizedSize(
		for source: NativeModelImageSize,
		minSize: Int,
		maxSize: Int
	) -> NativeModelImageSize? {
		guard source.isEmpty == false, minSize > 0, maxSize > 0 else { return nil }
		let shortSide = Double(min(source.width, source.height))
		let longSide = Double(max(source.width, source.height))
		let scale = min(Double(minSize) / shortSide, Double(maxSize) / longSide)
		// `Int(_: Double)` is a runtime trap for a non-finite or out-of-range value, so the products are
		// range-checked before the conversion rather than after it. This is a trust boundary: the region
		// sizes arrive from whatever wires this up.
		let scaledWidth = (Double(source.width) * scale).rounded(.down)
		let scaledHeight = (Double(source.height) * scale).rounded(.down)
		guard scaledWidth >= 1, scaledHeight >= 1,
			  let width = checkedInt(scaledWidth), let height = checkedInt(scaledHeight)
		else { return nil }
		return NativeModelImageSize(width: width, height: height)
	}

	/// Each dimension rounded up to a multiple of `strideDivisible`, per `batch_images`.
	public static func canvasSize(for resized: NativeModelImageSize, strideDivisible: Int) -> NativeModelImageSize? {
		guard resized.isEmpty == false, strideDivisible > 0,
			  resized.width <= Int.max - strideDivisible, resized.height <= Int.max - strideDivisible
		else { return nil }
		func rounded(_ value: Int) -> Int {
			(value + strideDivisible - 1) / strideDivisible * strideDivisible
		}
		return NativeModelImageSize(width: rounded(resized.width), height: rounded(resized.height))
	}

	/// The geometry torchvision itself would produce: resize by the transform's rule, pad to the
	/// stride.
	public static func geometry(
		source: NativeModelImageSize,
		minSize: Int,
		maxSize: Int,
		strideDivisible: Int
	) -> Geometry? {
		guard let resized = resizedSize(for: source, minSize: minSize, maxSize: maxSize),
			  let canvas = canvasSize(for: resized, strideDivisible: strideDivisible)
		else { return nil }
		return Geometry(sourceSize: source, resizedSize: resized, canvasSize: canvas)
	}

	/// The same resize laid onto a **fixed** canvas — what a Core ML graph with a static input shape
	/// requires.
	///
	/// The canvas is the emitted graph's business (AIA-0675 items 3 and 5), not this slice's, so it is
	/// supplied rather than chosen here. Note that a canvas whose shape differs from the stride-rounded
	/// one changes the anchor grid the network sees; `NATIVE_MODEL_CONVERSION.md` records the
	/// constraint that hands to AIA-0675.
	public static func geometry(
		source: NativeModelImageSize,
		minSize: Int,
		maxSize: Int,
		canvas: NativeModelImageSize
	) -> Geometry? {
		guard let resized = resizedSize(for: source, minSize: minSize, maxSize: maxSize),
			  canvas.isEmpty == false,
			  canvas.width >= resized.width, canvas.height >= resized.height
		else { return nil }
		return Geometry(sourceSize: source, resizedSize: resized, canvasSize: canvas)
	}

	// MARK: - Checked conversions

	/// `Int(_: Double)` is a runtime **trap**, not a nil, for a non-finite or out-of-range value — and
	/// `Double(Int.max)` rounds up to exactly 2^63, which is already out of range. Every conversion at
	/// this type's trust boundary goes through here instead.
	private static func checkedInt(_ value: Double) -> Int? {
		guard value.isFinite, value.magnitude < Double(Int.max / 2) else { return nil }
		return Int(value)
	}

	/// `channels · width · height`, or `nil` if that product overflows.
	///
	/// A guard written as `buffer.count == channels * width * height` traps on the multiplication
	/// before it can compare anything, so the sizes have to be multiplied defensively rather than
	/// checked afterwards.
	private static func elementCount(channels: Int, size: NativeModelImageSize) -> Int? {
		guard channels > 0, size.isEmpty == false else { return nil }
		let (plane, planeOverflowed) = size.width.multipliedReportingOverflow(by: size.height)
		guard planeOverflowed == false else { return nil }
		let (total, totalOverflowed) = plane.multipliedReportingOverflow(by: channels)
		guard totalOverflowed == false else { return nil }
		return total
	}

	// MARK: - Cropping a region

	/// A region crop, in the two forms the detect path needs it in.
	public struct CropPlan: Equatable, Sendable {
		/// The pixels to copy, rounded to whole pixels because a crop cannot be fractional.
		public let pixelRect: NativeModelPixelRect
		/// The region that crop **actually** covers, renormalised from `pixelRect`.
		///
		/// This is the value to hand `TileLayout.remap`, not the region that was asked for. A third of
		/// a page almost never lands on a pixel boundary, and remapping through the ideal `1/3` after
		/// cropping a rounded rectangle displaces every box in that tile by up to a pixel — which is
		/// precisely the error AIA-0680 declares detectable.
		public let effectiveRegion: NativeModelNormalizedRect
	}

	/// Plans the crop for one tiling region.
	///
	/// `frame` is in **pixels** — `cgImage.width`/`.height`, never `UIImage.size`, which is in points
	/// and differs by the screen scale on the snapshot fallback path.
	public static func cropPlan(
		frame: NativeModelImageSize,
		region: NativeModelNormalizedRect
	) -> CropPlan? {
		// Every component is checked before any arithmetic: `Int(_: Double)` traps on a non-finite or
		// out-of-range value, and the clamp below cannot run before the conversion. `sourceBox` guards
		// the same way; this was the one entry point that did not.
		guard frame.isEmpty == false,
			  region.x.isFinite, region.y.isFinite, region.width.isFinite, region.height.isFinite,
			  region.width > 0, region.height > 0,
			  region.x >= -1, region.y >= -1, region.x + region.width <= 2, region.y + region.height <= 2
		else { return nil }
		let width = Double(frame.width)
		let height = Double(frame.height)
		// Vision's origin is bottom-left; a raster crop's is top-left, so the far edge becomes the near
		// one. Each edge is rounded independently, then the far edges are pulled back inside the frame.
		let left = (region.x * width).rounded()
		let right = ((region.x + region.width) * width).rounded()
		let top = ((1 - (region.y + region.height)) * height).rounded()
		let bottom = ((1 - region.y) * height).rounded()

		guard let leftPixel = checkedInt(left), let rightPixel = checkedInt(right),
			  let topPixel = checkedInt(top), let bottomPixel = checkedInt(bottom)
		else { return nil }
		let x0 = max(0, min(frame.width, leftPixel))
		let x1 = max(0, min(frame.width, rightPixel))
		let y0 = max(0, min(frame.height, topPixel))
		let y1 = max(0, min(frame.height, bottomPixel))
		guard x1 > x0, y1 > y0 else { return nil }

		let pixelRect = NativeModelPixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
		let effective = NativeModelNormalizedRect(
			x: Double(x0) / width,
			y: Double(frame.height - y1) / height,
			width: Double(x1 - x0) / width,
			height: Double(y1 - y0) / height
		)
		return CropPlan(pixelRect: pixelRect, effectiveRegion: effective)
	}

	// MARK: - Resampling

	/// Bilinear resampling with PyTorch's `align_corners=False` half-pixel rule, over a planar
	/// `[channel][row][column]` buffer of `Float`.
	///
	/// Planar float is torchvision's own layout, so the oracle comparison is like-for-like rather than
	/// mediated by a conversion that could hide an error. The ratios come from the integer sizes, per
	/// axis, exactly as ATen's `area_pixel_compute_scale` does when no explicit scale is passed —
	/// which is the case under `recompute_scale_factor=True`.
	public static func resample(
		_ source: [Float],
		channels: Int,
		from sourceSize: NativeModelImageSize,
		to targetSize: NativeModelImageSize
	) -> [Float]? {
		guard let sourceCount = elementCount(channels: channels, size: sourceSize),
			  elementCount(channels: channels, size: targetSize) != nil,
			  source.count == sourceCount
		else { return nil }

		let columns = axisMapping(from: sourceSize.width, to: targetSize.width)
		let rows = axisMapping(from: sourceSize.height, to: targetSize.height)

		var output = [Float](repeating: 0, count: channels * targetSize.width * targetSize.height)
		for channel in 0..<channels {
			let sourcePlane = channel * sourceSize.width * sourceSize.height
			let targetPlane = channel * targetSize.width * targetSize.height
			for (targetRow, row) in rows.enumerated() {
				let top = sourcePlane + row.low * sourceSize.width
				let bottom = sourcePlane + row.high * sourceSize.width
				let targetRowStart = targetPlane + targetRow * targetSize.width
				for (targetColumn, column) in columns.enumerated() {
					let topLeft = Double(source[top + column.low])
					let topRight = Double(source[top + column.high])
					let bottomLeft = Double(source[bottom + column.low])
					let bottomRight = Double(source[bottom + column.high])
					let upper = topLeft * column.lowWeight + topRight * column.highWeight
					let lower = bottomLeft * column.lowWeight + bottomRight * column.highWeight
					output[targetRowStart + targetColumn] = Float(upper * row.lowWeight + lower * row.highWeight)
				}
			}
		}
		return output
	}

	/// One axis of the sampling grid: which two source indices each output index reads, and with what
	/// weights.
	private struct AxisTap {
		let low: Int
		let high: Int
		let lowWeight: Double
		let highWeight: Double
	}

	private static func axisMapping(from sourceLength: Int, to targetLength: Int) -> [AxisTap] {
		// Always `input / output`, including when the output is a single pixel.
		//
		// ATen's `area_pixel_compute_scale` does have an `output_size > 1 ? … : 0` guard, but it sits
		// **inside** the `align_corners` branch. Under `align_corners=false` — this component's whole
		// contract — the scale is `input_size / output_size` at every output length, so a one-pixel
		// axis samples the source *centre*, not its first pixel. Resizing `[10, 20, 30, 40]` to length
		// one gives 25.0 under this rule and 10.0 under the other; torchvision gives 25.0.
		//
		// It is reachable: a 2×2000 region binds on `maxSize` and resizes to 1×1333.
		let scale = Double(sourceLength) / Double(targetLength)
		return (0..<targetLength).map { index in
			// `area_pixel_compute_source_index`: clamped at zero for align_corners=false, which is why
			// the first output pixel of an upscale reads the first source pixel exactly.
			let sourceIndex = max(0, scale * (Double(index) + 0.5) - 0.5)
			let low = min(Int(sourceIndex.rounded(.down)), sourceLength - 1)
			let high = min(low + 1, sourceLength - 1)
			let highWeight = sourceIndex - Double(low)
			return AxisTap(low: low, high: high, lowWeight: 1 - highWeight, highWeight: highWeight)
		}
	}

	// MARK: - Padding

	/// torchvision's `image_mean` expressed in pixels, `255 · [0.485, 0.456, 0.406]`.
	///
	/// This is the padding fill, and the choice is forced by where normalisation lives. `batch_images`
	/// pads the **normalised** tensor with zeros; the graph normalises after this buffer is built; and
	/// bilinear interpolation is a convex combination, so it commutes with the per-channel affine
	/// exactly. Filling with the mean pixel therefore reproduces torchvision's zero padding — in real
	/// arithmetic. Through an 8-bit image input it does not quite: 123.675 is not representable, and
	/// the residual after normalisation is measured and stated by the tests rather than described as
	/// zero.
	public static let imageNetMeanPixels: [Float] = [0.485 * 255, 0.456 * 255, 0.406 * 255]

	/// Lays resized content onto the padded canvas: top-left origin, padding right and bottom.
	public static func canvas(
		from resized: [Float],
		channels: Int,
		geometry: Geometry,
		fill: [Float]
	) -> [Float]? {
		let resizedSize = geometry.resizedSize
		let canvasSize = geometry.canvasSize
		guard fill.count == channels,
			  let resizedCount = elementCount(channels: channels, size: resizedSize),
			  elementCount(channels: channels, size: canvasSize) != nil,
			  resized.count == resizedCount,
			  canvasSize.width >= resizedSize.width, canvasSize.height >= resizedSize.height
		else { return nil }

		var output = [Float](repeating: 0, count: channels * canvasSize.width * canvasSize.height)
		for channel in 0..<channels {
			let canvasPlane = channel * canvasSize.width * canvasSize.height
			let resizedPlane = channel * resizedSize.width * resizedSize.height
			let fillValue = fill[channel]
			for row in 0..<canvasSize.height {
				let canvasRow = canvasPlane + row * canvasSize.width
				guard row < resizedSize.height else {
					for column in 0..<canvasSize.width { output[canvasRow + column] = fillValue }
					continue
				}
				let resizedRow = resizedPlane + row * resizedSize.width
				for column in 0..<resizedSize.width {
					output[canvasRow + column] = resized[resizedRow + column]
				}
				for column in resizedSize.width..<canvasSize.width { output[canvasRow + column] = fillValue }
			}
		}
		return output
	}

	/// Resize and pad in one call — the whole forward pass, given a geometry.
	public static func size(
		_ source: [Float],
		channels: Int,
		geometry: Geometry,
		fill: [Float] = imageNetMeanPixels
	) -> [Float]? {
		guard let resized = resample(
			source, channels: channels, from: geometry.sourceSize, to: geometry.resizedSize
		) else { return nil }
		return canvas(from: resized, channels: channels, geometry: geometry, fill: fill)
	}

	/// Resize a 32-bit BGRA source directly onto the padded RGB canvas.
	///
	/// The detector's host input arrives in this format. Sampling it directly avoids first expanding
	/// every source pixel into a planar Float buffer — a full-page screenshot can be much larger than
	/// the fixed model canvas. The arithmetic intentionally mirrors `resample` followed by `canvas`:
	/// callers get the same torchvision-aligned output while keeping only the input bytes and one
	/// canvas-sized Float buffer live.
	public static func size(
		interleavedBGRA source: [UInt8],
		geometry: Geometry,
		fill: [Float] = imageNetMeanPixels
	) -> [Float]? {
		let sourceSize = geometry.sourceSize
		let resizedSize = geometry.resizedSize
		let canvasSize = geometry.canvasSize
		guard let sourceByteCount = elementCount(channels: 4, size: sourceSize),
			let canvasElementCount = elementCount(channels: 3, size: canvasSize),
			fill.count == 3,
			source.count == sourceByteCount,
			canvasSize.width >= resizedSize.width,
			canvasSize.height >= resizedSize.height
		else { return nil }

		let columns = axisMapping(from: sourceSize.width, to: resizedSize.width)
		let rows = axisMapping(from: sourceSize.height, to: resizedSize.height)
		let canvasPixels = canvasSize.width * canvasSize.height
		var output = [Float](repeating: 0, count: canvasElementCount)

		for channel in 0..<3 {
			let canvasPlane = channel * canvasPixels
			let byteOffset = [2, 1, 0][channel]
			for row in 0..<canvasSize.height {
				let canvasRow = canvasPlane + row * canvasSize.width
				guard row < resizedSize.height else {
					for column in 0..<canvasSize.width { output[canvasRow + column] = fill[channel] }
					continue
				}
				let taps = rows[row]
				let top = taps.low * sourceSize.width
				let bottom = taps.high * sourceSize.width
				for column in 0..<resizedSize.width {
					let tap = columns[column]
					let topLeft = Double(source[(top + tap.low) * 4 + byteOffset])
					let topRight = Double(source[(top + tap.high) * 4 + byteOffset])
					let bottomLeft = Double(source[(bottom + tap.low) * 4 + byteOffset])
					let bottomRight = Double(source[(bottom + tap.high) * 4 + byteOffset])
					let upper = topLeft * tap.lowWeight + topRight * tap.highWeight
					let lower = bottomLeft * tap.lowWeight + bottomRight * tap.highWeight
					output[canvasRow + column] = Float(upper * taps.lowWeight + lower * taps.highWeight)
				}
				for column in resizedSize.width..<canvasSize.width {
					output[canvasRow + column] = fill[channel]
				}
			}
		}

		return output
	}

	/// Packs a planar `[0, 255]` float buffer into the interleaved 8-bit **BGRA** bytes a
	/// `CVPixelBuffer` of `kCVPixelFormatType_32BGRA` holds.
	///
	/// This step is here rather than at the app boundary because it is where two silent errors live
	/// and neither is visible to a geometry test. First, the channel order inverts: the emitted model
	/// declares `colorSpace: .rgb` (`NativeModelImagePreprocessing.swift`, encoded at
	/// `NativeModelCoreMLEmitter.swift:1344`) while the exercised harness feeds BGRA
	/// (`NativeModelCoreMLEmitterTests.swift:202`), so writing the channels in array order swaps red
	/// and blue — a change no bounding box would reveal and no round trip would fail. Second, this is
	/// where the resampler's fractional output is rounded to what 8 bits can carry; Core ML image
	/// features have no float variant, so production pays this whether or not anyone measures it.
	///
	/// `planar` is `[channel][row][column]` with `channels == 3` in **RGB** order, matching
	/// torchvision. Alpha is written opaque.
	public static func interleavedBGRA(from planar: [Float], size: NativeModelImageSize) -> [UInt8]? {
		guard let planarCount = elementCount(channels: 3, size: size),
			  let byteCount = elementCount(channels: 4, size: size),
			  planar.count == planarCount
		else { return nil }
		let pixels = size.width * size.height
		var output = [UInt8](repeating: 255, count: byteCount)
		for pixel in 0..<pixels {
			output[pixel * 4] = byte(planar[2 * pixels + pixel])
			output[pixel * 4 + 1] = byte(planar[pixels + pixel])
			output[pixel * 4 + 2] = byte(planar[pixel])
		}
		return output
	}

	private static func byte(_ value: Float) -> UInt8 {
		UInt8(min(255, max(0, value.rounded())))
	}

	/// Rounds a `[0, 255]` buffer to the values an 8-bit image input can actually carry.
	///
	/// Production cannot skip this: Core ML image features are 8-bit
	/// (`NativeModelImagePreprocessing.ColorSpace` offers grayscale, RGB and BGR and nothing float),
	/// so the resampler's fractional output is quantised on its way into the pixel buffer whether or
	/// not anyone measures it. Measuring it is the point.
	public static func quantizedToByteRange(_ buffer: [Float]) -> [Float] {
		buffer.map { min(255, max(0, $0.rounded())) }
	}

	/// Applies the same affine the emitted graph carries, so a test can compare a buffer against
	/// torchvision's **normalised** output.
	///
	/// This mirrors the emitted scale layer; it does not replace it. The assertion it supports is
	/// against numbers torchvision produced, not against a second copy of this arithmetic.
	public static func normalized(
		_ buffer: [Float],
		channels: Int,
		size: NativeModelImageSize,
		preprocessing: NativeModelImagePreprocessing
	) -> [Float]? {
		guard channels > 0, channels == preprocessing.channelCount,
			  // `NativeModelImagePreprocessing` has a public memberwise initialiser, so its scale and bias
			  // arrays are not guaranteed to match the colour space's channel count.
			  preprocessing.scale.count == channels, preprocessing.bias.count == channels,
			  let expected = elementCount(channels: channels, size: size),
			  buffer.count == expected
		else { return nil }
		var output = buffer
		let plane = size.width * size.height
		for channel in 0..<channels {
			let scale = preprocessing.scale[channel]
			let bias = preprocessing.bias[channel]
			for index in (channel * plane)..<((channel + 1) * plane) {
				output[index] = output[index] * scale + bias
			}
		}
		return output
	}

	// MARK: - The inverse
}

public extension NativeModelImageSizing.Geometry {

	/// Maps a detected box from the model's canvas back to the crop it was sized from.
	///
	/// Both the input and the result are in Vision's convention — unit square, origin bottom-left —
	/// because that is what `VNRecognizedObjectObservation.boundingBox` carries and what
	/// `TileLayout.remap` consumes. The flip happens here, once, rather than at a call site where a
	/// padded bottom edge would quietly become a padded top edge.
	///
	/// The box is **clipped to the content rectangle** before un-scaling. A detection straddling the
	/// pad boundary is a real thing a detector produces, and passing its padded part through would
	/// place it outside the crop; leaving the clamp to `TileLayout.remap` would not catch it either,
	/// since that clamps at the *page* edge (`DetectionTiling.swift:126-128`), which is somewhere else
	/// entirely. Returns `nil` when nothing survives the clip.
	func sourceBox(fromCanvasBox box: NativeModelNormalizedRect) -> NativeModelNormalizedRect? {
		guard sourceSize.isEmpty == false, resizedSize.isEmpty == false, canvasSize.isEmpty == false,
			  box.width > 0, box.height > 0,
			  box.x.isFinite, box.y.isFinite, box.width.isFinite, box.height.isFinite
		else { return nil }

		let canvasWidth = Double(canvasSize.width)
		let canvasHeight = Double(canvasSize.height)
		// Vision (bottom-left) to raster (top-left), in canvas pixels.
		let left = box.x * canvasWidth
		let right = (box.x + box.width) * canvasWidth
		let top = (1 - (box.y + box.height)) * canvasHeight
		let bottom = (1 - box.y) * canvasHeight

		// Clip to the content, which occupies the canvas's top-left corner.
		let clippedLeft = max(0, left)
		let clippedRight = min(Double(resizedSize.width), right)
		let clippedTop = max(0, top)
		let clippedBottom = min(Double(resizedSize.height), bottom)
		guard clippedRight > clippedLeft, clippedBottom > clippedTop else { return nil }

		// `resize_boxes`: multiply by original ÷ new, per axis, from the integer sizes.
		let horizontal = Double(sourceSize.width) / Double(resizedSize.width)
		let vertical = Double(sourceSize.height) / Double(resizedSize.height)
		let sourceLeft = clippedLeft * horizontal
		let sourceRight = clippedRight * horizontal
		let sourceTop = clippedTop * vertical
		let sourceBottom = clippedBottom * vertical

		let sourceWidth = Double(sourceSize.width)
		let sourceHeight = Double(sourceSize.height)
		return NativeModelNormalizedRect(
			x: sourceLeft / sourceWidth,
			y: (sourceHeight - sourceBottom) / sourceHeight,
			width: (sourceRight - sourceLeft) / sourceWidth,
			height: (sourceBottom - sourceTop) / sourceHeight
		)
	}

	/// The forward direction of `sourceBox(fromCanvasBox:)`, for tests that need to place a known box
	/// on the canvas and for anything that has to draw the model's view of a crop.
	func canvasBox(fromSourceBox box: NativeModelNormalizedRect) -> NativeModelNormalizedRect? {
		guard sourceSize.isEmpty == false, resizedSize.isEmpty == false, canvasSize.isEmpty == false,
			  box.width > 0, box.height > 0
		else { return nil }

		let sourceWidth = Double(sourceSize.width)
		let sourceHeight = Double(sourceSize.height)
		let left = box.x * sourceWidth
		let right = (box.x + box.width) * sourceWidth
		let top = (1 - (box.y + box.height)) * sourceHeight
		let bottom = (1 - box.y) * sourceHeight

		let horizontal = Double(resizedSize.width) / sourceWidth
		let vertical = Double(resizedSize.height) / sourceHeight
		let canvasWidth = Double(canvasSize.width)
		let canvasHeight = Double(canvasSize.height)
		let canvasLeft = left * horizontal
		let canvasRight = right * horizontal
		let canvasTop = top * vertical
		let canvasBottom = bottom * vertical

		return NativeModelNormalizedRect(
			x: canvasLeft / canvasWidth,
			y: (canvasHeight - canvasBottom) / canvasHeight,
			width: (canvasRight - canvasLeft) / canvasWidth,
			height: (canvasBottom - canvasTop) / canvasHeight
		)
	}
}
