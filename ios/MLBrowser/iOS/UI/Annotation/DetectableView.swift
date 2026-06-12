//
//  DetectableView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 03.12.24.
//

import SwiftUI
import Combine
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
    let tiledDetection: Bool

    /// Callback to receive interaction state changes. DetectableView manages state internally.
    private let onInteractionStateChanged: ((ContentInteractionState) -> Void)?

    @ViewBuilder let content: (Binding<ContentInteractionState>) -> Content

    @State private var detectedObservations: [DetectionResult] = []
    @State private var interactionState: ContentInteractionState = .idle
    @State private var detectionGeneration: UInt64 = 0
    @State private var detectionQueue = SnapshotDetectionQueue()

    /// Initializer with interaction state callback - content receives a binding to update state
    init(
        renderer: DefaultRenderer,
        drivers: DeepDrivers,
        trigger: P,
        showIdentifiers: Bool,
        tiledDetection: Bool = false,
        onInteractionStateChanged: ((ContentInteractionState) -> Void)? = nil,
        @ViewBuilder content: @escaping (Binding<ContentInteractionState>) -> Content
    ) {
        self.renderer = renderer
        self.drivers = drivers
        self.trigger = trigger
        self.showIdentifiers = showIdentifiers
        self.tiledDetection = tiledDetection
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
                #if DEBUG
                LoggingPolicy.debug("GeometrySizeChange: \(old.width)x\(old.height) -> \(new.width)x\(new.height)", logger: .ui)
                #endif
                detectionGeneration &+= 1
                detectedObservations.removeAll()
                // A coalesced snapshot was captured against the old geometry; if it
                // started later it would read the NEW generation and its stale boxes
                // would pass the guard below.
                detectionQueue.cancelPending()
            }
        }
        .onSnapshot { image, _ in
            // Skip detection while content is being manipulated - geometry is changing
            guard !isInteracting else { return }
            // The queue serializes passes and coalesces snapshots arriving mid-pass to
            // the newest one: a tiled pass (6 inferences × N detectors) can outlast the
            // snapshot cadence, and overlapping passes would apply out of order.
            detectionQueue.enqueue(image) { image, done in
                let currentGeneration = detectionGeneration
                drivers.detect(on: image, tiledDetection: tiledDetection) { observations in
                    done()
                    // Discard if interaction started since detection began (stale results)
                    guard detectionGeneration == currentGeneration else {
                        return
                    }
                    // Double-check interaction state before applying results
                    guard !isInteracting else { return }
                    detectedObservations = observations
                }
            }
        }
        .onChange(of: interactionState) { _, state in
            if state.isInteracting {
                // Invalidate any in-flight detections
                detectionGeneration &+= 1
                // Clear annotations immediately when interaction starts
                detectedObservations.removeAll()
                // A coalesced snapshot was captured pre-interaction — stale geometry.
                detectionQueue.cancelPending()
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
    let observations: [DetectionResult]
    let geometry: GeometryProxy
    let showIdentifiers: Bool

    var body: some View {
        ForEach(Array(observations.enumerated()), id: \.offset) { _, observationGroup in
            ForEach(observationGroup.observations, id: \.uuid) { detection in
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

/// Serializes detection passes: at most one in flight, with snapshots arriving mid-pass
/// coalesced to the newest (latest wins, no queue growth). Applying results in completion
/// order is what made overlapping passes able to deliver frame A's boxes after frame B's.
@MainActor
final class SnapshotDetectionQueue {
    typealias Pass = @MainActor (UIImage, _ done: @escaping @MainActor () -> Void) -> Void

    private(set) var inFlight = false
    private var pendingImage: UIImage?

    func enqueue(_ image: UIImage, pass: @escaping Pass) {
        guard inFlight.not else {
            pendingImage = image
            return
        }
        start(image, pass: pass)
    }

    /// Drops a coalesced snapshot (e.g. interaction started — its geometry is stale).
    func cancelPending() {
        pendingImage = nil
    }

    private func start(_ image: UIImage, pass: @escaping Pass) {
        inFlight = true
        pass(image) { [weak self] in
            guard let self else { return }
            self.inFlight = false
            if let next = self.pendingImage {
                self.pendingImage = nil
                self.start(next, pass: pass)
            }
        }
    }
}
