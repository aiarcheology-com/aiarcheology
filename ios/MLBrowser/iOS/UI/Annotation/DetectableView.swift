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

/// Tracks whether content is being actively manipulated (scroll, drag, zoom, etc.)
/// This invalidates the current detection results since geometry is changing.
public enum ContentInteractionState {
    case idle
    case interacting
    
    public var isInteracting: Bool { self == .interacting }
}

/// A reusable view wrapper that handles detection and annotation in one coordinated scope.
/// This ensures the snapshot geometry and annotation overlay share the same coordinate space.
///
/// The `onInteractionStateChanged` callback allows any content to signal when it's being manipulated:
/// - For WKWebView: called from UIScrollViewDelegate callbacks or JS message handler
/// - For SwiftUI ScrollView: called from DragGesture handlers
/// - For image viewers: called from MagnificationGesture/DragGesture handlers
struct DetectableView<Content: View, P>: View where P: Publisher, P.Failure == Never {
    let renderer: DefaultRenderer
    let drivers: DeepDrivers
    let trigger: P
    let showIdentifiers: Bool
    
    /// Callback to receive interaction state changes. DetectableView manages state internally.
    private let onInteractionStateChanged: ((ContentInteractionState) -> Void)?
    
    @ViewBuilder let content: (Binding<ContentInteractionState>) -> Content
    
    @State private var detectedObservations: [ObservationParams] = []
    @State private var interactionState: ContentInteractionState = .idle
    @State private var detectionGeneration: UInt64 = 0
    
    /// Initializer with interaction state callback - content receives a binding to update state
    init(
        renderer: DefaultRenderer,
        drivers: DeepDrivers,
        trigger: P,
        showIdentifiers: Bool,
        onInteractionStateChanged: ((ContentInteractionState) -> Void)? = nil,
        @ViewBuilder content: @escaping (Binding<ContentInteractionState>) -> Content
    ) {
        self.renderer = renderer
        self.drivers = drivers
        self.trigger = trigger
        self.showIdentifiers = showIdentifiers
        self.onInteractionStateChanged = onInteractionStateChanged
        self.content = content
    }
    
    private var isInteracting: Bool {
        interactionState.isInteracting
    }
    
    var body: some View {
        return GeometryReader { geometry in
            ZStack {
                // Snapshottable content - pass binding so content can update interaction state
                SnapableGroup(renderer: renderer, publisher: trigger) {
                    content($interactionState)
                }
                
                // Annotation overlay - SAME geometry scope guarantees coordinate alignment
                AnnotationOverlay(
                    observations: detectedObservations,
                    geometry: geometry,
                    showIdentifiers: showIdentifiers
                )
            }
            .onChange(of: geometry.size) { old, new in
                // Layout changed (chrome shown/hidden, rotation): results captured
                // against the previous geometry would draw misaligned boxes.
                LoggingPolicy.debug("GeometrySizeChange: \(old.width)x\(old.height) -> \(new.width)x\(new.height)", logger: .ui)
                detectionGeneration &+= 1
                detectedObservations.removeAll()
            }
        }
        .onSnapshot { image, _ in
            // Skip detection while content is being manipulated - geometry is changing
            guard !isInteracting else { return }
            let currentGeneration = detectionGeneration
            drivers.detect(on: image) { observations in
                // Discard if interaction started since detection began (stale results)
                guard detectionGeneration == currentGeneration else {
                    return
                }
                // Double-check interaction state before applying results
                guard !isInteracting else { return }
                detectedObservations = observations
            }
        }
        .onChange(of: interactionState) { _, state in
            if state.isInteracting {
                // Invalidate any in-flight detections
                detectionGeneration &+= 1
                // Clear annotations immediately when interaction starts
                detectedObservations.removeAll()
            }
            // Notify external observer if provided
            onInteractionStateChanged?(state)
        }
    }
}

// MARK: - SwiftUI Gesture-based Interaction Tracking

extension View {
    /// Adds drag gesture tracking to a view, updating the provided interaction state binding.
    /// Use this for pure SwiftUI content that needs interaction tracking with DetectableView.
    ///
    /// Example:
    /// ```swift
    /// DetectableView(...) { interactionState in
    ///     ScrollView {
    ///         content
    ///     }
    ///     .trackingInteraction(interactionState)
    /// }
    /// ```
    func trackingInteraction(_ state: Binding<ContentInteractionState>) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if state.wrappedValue != .interacting {
                        state.wrappedValue = .interacting
                    }
                }
                .onEnded { _ in
                    state.wrappedValue = .idle
                }
        )
    }
    
    /// Adds magnification (pinch-to-zoom) gesture tracking to a view.
    func trackingMagnification(_ state: Binding<ContentInteractionState>) -> some View {
        self.simultaneousGesture(
            MagnificationGesture()
                .onChanged { _ in
                    if state.wrappedValue != .interacting {
                        state.wrappedValue = .interacting
                    }
                }
                .onEnded { _ in
                    state.wrappedValue = .idle
                }
        )
    }
    
    /// Combines drag and magnification tracking for views that support both.
    func trackingAllInteractions(_ state: Binding<ContentInteractionState>) -> some View {
        self
            .trackingInteraction(state)
            .trackingMagnification(state)
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
