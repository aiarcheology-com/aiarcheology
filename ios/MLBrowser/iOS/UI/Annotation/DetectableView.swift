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
    /// Finding-flash style (AIA-0374) — plain value like `showIdentifiers`, refreshed
    /// by the call site; the view deliberately does not observe `Settings`.
    let flashStyle: FlashStyle

    /// Callback to receive interaction state changes. DetectableView manages state internally.
    private let onInteractionStateChanged: ((ContentInteractionState) -> Void)?

    /// True while a finding capture (pick mode or save dialog) is active. Owned by
    /// the presenting screen; while set, the displayed frame is frozen: nothing may
    /// clear or replace `appliedFrame` (geometry/interaction clearers, the apply
    /// site, and new enqueues are all gated on it).
    private var isCapturingFinding: Binding<Bool>

    /// Mirrors every write/clear of the displayed frame to the presenting screen —
    /// the find-pick flow hit-tests the frozen frame's boxes and reuses its
    /// snapshot, and the mirror can never diverge from what's drawn.
    private let onFrameChanged: ((AppliedDetectionFrame?) -> Void)?

    @ViewBuilder let content: (Binding<ContentInteractionState>) -> Content

    @State private var appliedFrame: AppliedDetectionFrame?
    @State private var interactionState: ContentInteractionState = .idle
    @State private var detectionGeneration: UInt64 = 0
    @State private var detectionQueue = SnapshotDetectionQueue()
    /// Classification consumer (AIA-0374) — a parallel branch of the snapshot flow,
    /// independent of the detection queue/appliedFrame machinery above.
    @StateObject private var flashController = ClassificationFlashController()

    /// Initializer with interaction state callback - content receives a binding to update state
    init(
        renderer: DefaultRenderer,
        drivers: DeepDrivers,
        trigger: P,
        showIdentifiers: Bool,
        tiledDetection: Bool = false,
        flashStyle: FlashStyle,
        isCapturingFinding: Binding<Bool> = .constant(false),
        onFrameChanged: ((AppliedDetectionFrame?) -> Void)? = nil,
        onInteractionStateChanged: ((ContentInteractionState) -> Void)? = nil,
        @ViewBuilder content: @escaping (Binding<ContentInteractionState>) -> Content
    ) {
        self.renderer = renderer
        self.drivers = drivers
        self.trigger = trigger
        self.showIdentifiers = showIdentifiers
        self.tiledDetection = tiledDetection
        self.flashStyle = flashStyle
        self.isCapturingFinding = isCapturingFinding
        self.onFrameChanged = onFrameChanged
        self.onInteractionStateChanged = onInteractionStateChanged
        self.content = content
    }
    
    private var isInteracting: Bool {
        interactionState.isInteracting
    }

    /// Total rendered detection annotations across all result groups — the same `appliedFrame`
    /// results `AnnotationOverlay` draws. Extracted from `body` so the checkpoint expression stays
    /// within the type-checker budget (AIA-0317).
    private var renderedDetectionCount: Int {
        (appliedFrame?.results ?? []).reduce(0) { $0 + $1.observations.count }
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
                    observations: appliedFrame?.results ?? [],
                    geometry: geometry,
                    showIdentifiers: showIdentifiers
                )

                // Finding flash (AIA-0374): classification's presentation — no boxes
                // exist for whole-image results, so a qualifying classification flashes
                // the content frame. Non-interactive by requirement.
                FindingFlashOverlay(style: flashStyle, flashToken: flashController.flashCount)
            }
            .onChange(of: geometry.size) { old, new in
                // The save dialog freezes the displayed frame; a rotation underneath
                // merely misaligns the frozen boxes behind the sheet (cosmetic), while
                // clearing them would defeat the freeze.
                guard isCapturingFinding.wrappedValue.not else { return }
                // Layout changed (chrome shown/hidden, rotation): results captured
                // against the previous geometry would draw misaligned boxes.
                LoggingPolicy.debug("GeometrySizeChange: \(old.width)x\(old.height) -> \(new.width)x\(new.height)", logger: .ui)
                detectionGeneration &+= 1
                setAppliedFrame(nil)
                // A coalesced snapshot was captured against the old geometry; if it
                // started later it would read the NEW generation and its stale boxes
                // would pass the guard below.
                detectionQueue.cancelPending()
                // An in-flight classify pass saw the old-geometry frame (AIA-0374).
                flashController.invalidateInFlight()
            }
        }
        .onSnapshot { image, _ in
            // Skip detection while content is being manipulated - geometry is changing
            guard !isInteracting else { return }
            // The frozen frame must outlive the save dialog; new passes resume with
            // the timer once the capture ends.
            guard isCapturingFinding.wrappedValue.not else { return }
            // Classification branch (AIA-0374): parallel consumer of the same snapshot,
            // deliberately AFTER both guards above so a straggler frame can't
            // classify-and-flash mid-scroll or behind the save sheet. Independent of
            // the detection queue below.
            flashController.flashEnabled = flashStyle.enabled
            flashController.classifyPass(drivers: drivers, image: image)
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
                    // A pass that slipped past the guards before the tap froze the
                    // frame must not repaint the boxes the user is looking at.
                    guard isCapturingFinding.wrappedValue.not else { return }
                    // Image and results are applied as ONE value: the cached snapshot
                    // is always the exact frame the displayed boxes came from, so a
                    // pick can never pair boxes with a newer image.
                    setAppliedFrame(AppliedDetectionFrame(image: image, results: observations))
                }
            }
        }
        .onChange(of: isCapturingFinding.wrappedValue) { _, capturing in
            // Entering a capture must also invalidate work already in flight:
            // the freeze gate alone only discards results WHILE it is set — a
            // pre-freeze pass (or its coalesced successor) finishing after the
            // capture ends would briefly apply a stale frame over the fresh one.
            if capturing {
                detectionGeneration &+= 1
                detectionQueue.cancelPending()
                // A classify pass finishing behind the save sheet must not flash
                // over it (AIA-0374).
                flashController.invalidateInFlight()
            }
        }
        .onChange(of: interactionState) { _, state in
            // While the save dialog is up the frame stays frozen (interaction events
            // can still arrive from the web view as the sheet animates in).
            if state.isInteracting && isCapturingFinding.wrappedValue.not {
                // Invalidate any in-flight detections
                detectionGeneration &+= 1
                // Clear annotations immediately when interaction starts
                setAppliedFrame(nil)
                // A coalesced snapshot was captured pre-interaction — stale geometry.
                detectionQueue.cancelPending()
                // Classification mirrors detection's clear semantics: a still-present
                // finding flashes again once the content settles and re-qualifies
                // (0→n; AIA-0374 accepted behavior).
                flashController.resetOnInteraction()
            }
            // Notify external observer if provided
            onInteractionStateChanged?(state)
        }
        // AIA-0317: publish the live rendered-annotation count for UI tests. Attached at the body
        // root (outside the ZStack's SnapableGroup), so the 1pt marker is never in the detection
        // snapshot. Reads the same `appliedFrame.results` that feeds AnnotationOverlay, so the
        // count equals the visible annotation total (0 when none).
        // Gate the O(n) reduce on `isRunningUITests` so production view updates don't pay for a
        // value only the UI-test checkpoint marker reads (the marker itself already renders only
        // under UI tests).
        .checkpoint(.detectionCount, value: AppEnvironment.isRunningUITests ? String(renderedDetectionCount) : "")
        // AIA-0374: finding-flash introspection. flashCount is monotonic (polling can't
        // miss a transient); classificationCount lets the disable-case assert the flash
        // froze while classification kept running.
        .checkpoint(.flashCount, value: AppEnvironment.isRunningUITests ? String(flashController.flashCount) : "")
        .checkpoint(.classificationCount, value: AppEnvironment.isRunningUITests ? String(flashController.qualifyingCount) : "")
        // Propagate toggle changes to in-flight passes immediately — ingest reads the
        // controller's CURRENT enabled state, not a value captured at pass start
        // (AIA-0374 P4 review; the per-pass write above covers steady state).
        .onChange(of: flashStyle.enabled) { _, enabled in
            flashController.flashEnabled = enabled
        }
    }

    /// Single write path for the displayed frame: the screen's mirror is updated
    /// in the same statement, so the two can never diverge.
    private func setAppliedFrame(_ frame: AppliedDetectionFrame?) {
        appliedFrame = frame
        onFrameChanged?(frame)
    }
}

/// One displayed detection frame: the snapshot and the results detected ON that
/// snapshot, applied together so they can never diverge. The save-finding flow
/// captures this value at tap time.
struct AppliedDetectionFrame {
    let image: UIImage
    let results: [DetectionResult]
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
                    showIdentifiers: showIdentifiers
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
