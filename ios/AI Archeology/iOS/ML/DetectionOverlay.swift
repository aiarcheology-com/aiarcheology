//
//  DetectionOverlay.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 26.09.23.
//

import Foundation
import Vision
import SwiftUI

struct DetectionOverlayView: View {
    var observations: [VNRecognizedObjectObservation]
    var body: some View {
        GeometryReader { geometry in
            ForEach(observations, id: \.uuid) { observation in
                let boundingBox = observation.boundingBox
                let size = CGSize(width: boundingBox.size.width * geometry.size.width, height: boundingBox.size.height * geometry.size.height)
                let position = CGPoint(x: boundingBox.origin.x * geometry.size.width, y: (1 - boundingBox.origin.y - boundingBox.size.height) * geometry.size.height)

                Rectangle()
                    .fill(Color.clear)
                    .border(Color.red, width: 4)
                    .frame(width: size.width, height: size.height)
                    .position(position)
            }
        }
    }
}
