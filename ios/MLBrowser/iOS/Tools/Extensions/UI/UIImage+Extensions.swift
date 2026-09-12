//
//  UIImage+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 30.11.23.
//

import UIKit
import CoreImage

extension UIImage {
	/// Shared rendering context: creating a CIContext is expensive (GPU pipeline setup)
	/// and this method runs on every detection snapshot. CIContext is thread-safe.
	private static let adjustmentContext = CIContext(options: nil)

	func adjusted(brightness: CGFloat? = nil, contrast: CGFloat? = nil, saturation: CGFloat? = nil) -> UIImage {
		guard let ciImage = CIImage(image: self) else { return self }

		let filter = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: ciImage])

		if let brightness = brightness {
			filter?.setValue(brightness, forKey: "inputBrightness")
		}
		if let contrast = contrast {
			filter?.setValue(contrast, forKey: "inputContrast")
		}
		if let saturation = saturation {
			filter?.setValue(saturation, forKey: "inputSaturation")
		}

		guard let outputImage = filter?.outputImage,
			  let cgImage = Self.adjustmentContext.createCGImage(outputImage, from: outputImage.extent) else {
			return self
		}

		return UIImage(cgImage: cgImage)
	}
}
