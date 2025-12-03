//
//  DetectableView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 03.12.24.
//

import SwiftUI
import Combine
import Vision
import OSLog

/// A reusable view wrapper that handles detection and annotation in one coordinated scope.
/// This ensures the snapshot geometry and annotation overlay share the same coordinate space.
struct DetectableView<Content: View, P>: View where P: Publisher, P.Failure == Never {
    let renderer: DefaultRenderer
    let drivers: DeepDrivers
    let trigger: P
    let showIdentifiers: Bool
    @ViewBuilder let content: () -> Content
    
    @State private var detectedObservations: [ObservationParams] = []
    
    var body: some View {
        return GeometryReader { geometry in
            ZStack {
                // Snapshottable content
                SnapableGroup(renderer: renderer, publisher: trigger) {
                    content()
                }
                
                // Annotation overlay - SAME geometry scope guarantees coordinate alignment
                AnnotationOverlay(
                    observations: detectedObservations,
                    geometry: geometry,
                    showIdentifiers: showIdentifiers
                )
            }
        }
        .onSnapshot { image, frame in
            Task { @MainActor in
                drivers.detect(on: image) { observations in
                    detectedObservations = observations
                }
            }
        }
        .gesture(
            // Reset annotations when dragging the content
            DragGesture()
                .onEnded { _ in
                    detectedObservations.removeAll()
                }
        )
    }
}

/// Annotation overlay that renders detection results
/// Extracted to be used within the same GeometryReader scope as the detected content
struct AnnotationOverlay: View {
    let observations: [ObservationParams]
    let geometry: GeometryProxy
    let showIdentifiers: Bool
    
    var body: some View {
        ForEach(Array(observations.enumerated()), id: \.offset) { _, observationGroup in
            ForEach(observationGroup.observations, id: \.uuid) { observation in
                if let detection = observation as? VNRecognizedObjectObservation {
                    AnnotationViewBuilder(
                        observation: detection,
                        geometry: geometry,
                        params: observationGroup.params,
                        showIndentifiers: showIdentifiers
                    )
                }
            }
        }
    }
}
