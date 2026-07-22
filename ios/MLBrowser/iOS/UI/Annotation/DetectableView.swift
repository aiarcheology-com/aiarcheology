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
    let renderer: any SnapshotRendering
    let drivers: DeepDrivers
    let trigger: P
    let showIdentifiers: Bool
    /// Whether detection overlays animate on appear. `false` (settings.disableDetectionAnimations
    /// on) renders each marker at its static visible state — no per-frame pulse/scale/fade.
    let animateDetections: Bool
    let tiling: TilingScheme
    /// AIA-0426: draw a red border around each detector tile (the "Tiled Borders" setting, available
    /// in all builds from the Tiled Detection submenu). Purely visual — read from the same
    /// `TileLayout.regions(for:)` the detector uses; never affects detection.
    let tiledBorders: Bool
    /// Whether the detection/classification loop is running (play/pause). When it
    /// stops, the classification presentation must clear immediately — with no
    /// further snapshots the steady-state pulse/bubble would freeze forever
    /// (owner-reported, AIA-0374). Plain scalar per the showIdentifiers pattern.
    let detectionActive: Bool

    /// Callback to receive interaction state changes. DetectableView manages state internally.
    private let onInteractionStateChanged: ((ContentInteractionState) -> Void)?

    /// True while a finding capture (pick mode or save dialog) is active. Owned by
    /// the presenting screen; while set, the displayed frame is frozen: nothing may
    /// clear or replace `appliedFrame` (geometry/interaction clearers, the apply
    /// site, and new enqueues are all gated on it).
    private var isCapturingFinding: Binding<Bool>

    @ViewBuilder let content: (Binding<ContentInteractionState>) -> Content

    @State private var interactionState: ContentInteractionState = .idle
    /// The detection state machine (generation / coalesce / freeze / apply-guards), extracted so it
    /// is unit-testable without SwiftUI (AIA-0386). This view is now layout + event-forwarding.
    @StateObject private var coordinator: DetectionCoordinator
    /// Classification consumer (AIA-0374) — a parallel branch of the snapshot flow,
    /// independent of the detection queue/appliedFrame machinery above.
    @StateObject private var flashController = ClassificationFlashController()

    /// Initializer with interaction state callback - content receives a binding to update state
    init(
        renderer: any SnapshotRendering,
        drivers: DeepDrivers,
        trigger: P,
        showIdentifiers: Bool,
        animateDetections: Bool = true,
        tiling: TilingScheme = [],
        tiledBorders: Bool = false,
        detectionActive: Bool = false,
        isCapturingFinding: Binding<Bool> = .constant(false),
        onFrameChanged: ((AppliedDetectionFrame?) -> Void)? = nil,
        onInteractionStateChanged: ((ContentInteractionState) -> Void)? = nil,
        @ViewBuilder content: @escaping (Binding<ContentInteractionState>) -> Content
    ) {
        self.renderer = renderer
        self.drivers = drivers
        self.trigger = trigger
        self.showIdentifiers = showIdentifiers
        self.animateDetections = animateDetections
        self.tiling = tiling
        self.tiledBorders = tiledBorders
        self.detectionActive = detectionActive
        self.isCapturingFinding = isCapturingFinding
        self.onInteractionStateChanged = onInteractionStateChanged
        self.content = content
        // The detect seam is @MainActor (DeepDrivers is); the heavy work hops to the engine actor
        // inside detect(). Guards are bound later from the installed view's connected state
        // (.onAppear → bindGuards) — a view's own @State isn't wired to storage at init time.
        self._coordinator = StateObject(wrappedValue: DetectionCoordinator(
            tiling: tiling,
            detect: { image, tiling in await drivers.detect(on: image, tiling: tiling) },
            onFrameChanged: onFrameChanged
        ))
    }
    
    private var isInteracting: Bool {
        interactionState.isInteracting
    }

    /// Total rendered detection annotations across all result groups — the same `appliedFrame`
    /// results `AnnotationOverlay` draws. Extracted from `body` so the checkpoint expression stays
    /// within the type-checker budget (AIA-0317).
    private var renderedDetectionCount: Int {
        (coordinator.appliedFrame?.results ?? []).reduce(0) { $0 + $1.observations.count }
    }

    // Checkpoint values extracted from the `body` chain for the same type-checker-budget
    // reason as `renderedDetectionCount` (AIA-0317; flagged again by review on AIA-0374).
    private var flashCountValue: String {
        AppEnvironment.isRunningUITests ? String(flashController.qualifyingPassCount) : ""
    }
    private var classificationCountValue: String {
        AppEnvironment.isRunningUITests ? String(flashController.qualifyingCount) : ""
    }
    private var topClassificationValue: String {
        guard AppEnvironment.isRunningUITests else { return "" }
        return flashController.displayLabels.first.map { "\($0.identifier)=\($0.confidence)" } ?? ""
    }
    /// Number of tile-border outlines the overlay currently renders (AIA-0426): the `regions(for:)`
    /// count when Tiled Borders is on, `0` when off. Gated on UI tests so production pays nothing.
    private var tiledBorderCountValue: String {
        guard AppEnvironment.isRunningUITests else { return "" }
        return String(tiledBorders ? TileLayout.regions(for: tiling).count : 0)
    }

    var body: some View {
        return GeometryReader { geometry in
            ZStack {
                // Snapshottable content - pass binding so content can update interaction state
                SnapableGroup(renderer: renderer, publisher: trigger) {
                    content($interactionState)
                }

                // AIA-0426 debug: red borders around the tiles fed to the detector. Reads the SAME
                // TileLayout.regions(for:) the detector uses and never touches the detect path, so it
                // cannot change detections (the snapshot comes from WKWebView, not this view tree).
                if tiledBorders {
                    TileBorderOverlay(schemes: tiling, geometry: geometry)
                }

                // Annotation overlay - SAME geometry scope guarantees coordinate alignment
                AnnotationOverlay(
                    observations: coordinator.appliedFrame?.results ?? [],
                    geometry: geometry,
                    showIdentifiers: showIdentifiers,
                    animateDetections: animateDetections
                )

                // Finding flash (AIA-0374): classification's presentation — no boxes
                // exist for whole-image results, so the frame pulses while a qualifying
                // classification is on screen, styled by that model's configuration.
                // Non-interactive by requirement.
                FindingFlashOverlay(
                    active: flashController.qualifyingCount > 0,
                    color: flashController.flashColor,
                    period: flashController.pulsePeriod,
                    size: flashController.flashSize,
                    animateDetections: animateDetections
                )

                // Classified labels (AIA-0374): the same "Show labels" setting that
                // annotates detection boxes surfaces classification's top labels —
                // independent of the flash threshold, so low-confidence results are
                // still visible to the user.
                if showIdentifiers && flashController.displayGroups.isEmpty.not {
                    ClassificationLabelBubble(groups: flashController.displayGroups)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                }
            }
            .onChange(of: geometry.size) { old, new in
                // The save dialog freezes the displayed frame; a rotation underneath
                // merely misaligns the frozen boxes behind the sheet (cosmetic), while
                // clearing them would defeat the freeze.
                guard isCapturingFinding.wrappedValue.not else { return }
                // Layout changed (chrome shown/hidden, rotation): results captured
                // against the previous geometry would draw misaligned boxes.
                LoggingPolicy.debug("GeometrySizeChange: \(old.width)x\(old.height) -> \(new.width)x\(new.height)", logger: .ui)
                // The coordinator bumps the generation, clears the frame, and drops the
                // coalesced snapshot captured against the old geometry (AIA-0386).
                coordinator.geometryChanged()
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
            flashController.classifyPass(drivers: drivers, image: image)
            // Detection pipeline: serialize + coalesce + apply-guard live in the coordinator
            // (AIA-0386). This is the single detection entry point.
            coordinator.ingest(snapshot: image)
        }
        .onChange(of: isCapturingFinding.wrappedValue) { _, capturing in
            // Entering a capture must also invalidate work already in flight:
            // the freeze gate alone only discards results WHILE it is set — a
            // pre-freeze pass (or its coalesced successor) finishing after the
            // capture ends would briefly apply a stale frame over the fresh one.
            coordinator.setCapturing(capturing)
            if capturing {
                // A classify pass finishing behind the save sheet must not flash
                // over it (AIA-0374).
                flashController.invalidateInFlight()
            }
        }
        .onChange(of: interactionState) { _, state in
            // While the save dialog is up the frame stays frozen (interaction events
            // can still arrive from the web view as the sheet animates in).
            // The coordinator invalidates in-flight detection + clears the frame when
            // interaction starts (unless a capture is freezing it) — AIA-0386.
            coordinator.setInteracting(state.isInteracting)
            if state.isInteracting && isCapturingFinding.wrappedValue.not {
                // Classification mirrors detection's clear semantics: a still-present
                // finding flashes again once the content settles and re-qualifies
                // (0→n; AIA-0374 accepted behavior).
                flashController.resetOnInteraction()
            }
            // Notify external observer if provided
            onInteractionStateChanged?(state)
        }
        .onAppear {
            // Bind the coordinator's live apply-time guards from the installed view's CONNECTED
            // state (AIA-0386). Not done at init: the view's own @State isn't wired to persistent
            // storage yet at init time, so a closure captured there reads a dead initial value.
            coordinator.bindGuards(
                isInteracting: { interactionState.isInteracting },
                isCapturing: { isCapturingFinding.wrappedValue }
            )
        }
        .onChange(of: tiling) { _, value in
            // Keep the coordinator's live tiling scheme current (read at each pass start).
            coordinator.tiling = value
        }
        // AIA-0317: publish the live rendered-annotation count for UI tests. Attached at the body
        // root (outside the ZStack's SnapableGroup), so the 1pt marker is never in the detection
        // snapshot. Reads the same `appliedFrame.results` that feeds AnnotationOverlay, so the
        // count equals the visible annotation total (0 when none).
        // Gate the O(n) reduce on `isRunningUITests` so production view updates don't pay for a
        // value only the UI-test checkpoint marker reads (the marker itself already renders only
        // under UI tests).
        .checkpoint(.detectionCount, value: AppEnvironment.isRunningUITests ? String(renderedDetectionCount) : "")
        // AIA-0426: how many tile-border outlines the overlay is drawing — lets a UI test confirm
        // that enabling "Tiled Borders" actually renders borders (0 when the setting is off).
        .checkpoint(.tiledBorderCount, value: tiledBorderCountValue)
        // AIA-0374: finding-flash introspection. flashCount counts qualifying passes
        // (monotonic — polling can't miss a transient); classificationCount is the
        // number of currently-qualifying, flash-participating drivers.
        .checkpoint(.flashCount, value: flashCountValue)
        .checkpoint(.classificationCount, value: classificationCountValue)
        .checkpoint(.topClassification, value: topClassificationValue)
        .onChange(of: detectionActive) { _, active in
            // Pause/stop: clear the pulse + bubble now — no snapshots will arrive to
            // refresh or clear them (owner-reported freeze, AIA-0374).
            if active.not {
                flashController.clearPresentation()
            }
        }
        .onReceive(drivers.$classificators) { classificators in
            // Unregistering the last classify model must clear its presentation even
            // while paused (no pass will ever report empty results).
            if classificators.isEmpty {
                flashController.clearPresentation()
            }
        }
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

/// Overlay (AIA-0426): draws a red border around each tile fed to the detector so the tile split is
/// visible. Purely visual — it reads the same `TileLayout.regions(for:)` the detector uses and never
/// touches the detection path. Gated by the "Tiled Borders" setting (Tiled Detection submenu) upstream.
struct TileBorderOverlay: View {
    let schemes: TilingScheme
    let geometry: GeometryProxy

    var body: some View {
        ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
            Rectangle()
                .stroke(Color.red, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var rects: [CGRect] {
        TileLayout.regions(for: schemes).map { Self.screenRect(for: $0, in: geometry.size) }
    }

    /// Maps a normalized Vision-coordinate region (bottom-left origin) to a SwiftUI screen rect
    /// (top-left origin) — the same Y-flip the annotation views apply. Pure + static so it is unit
    /// testable without SwiftUI.
    static func screenRect(for region: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: region.minX * size.width,
            y: (1 - region.maxY) * size.height,
            width: region.width * size.width,
            height: region.height * size.height
        )
    }
}

/// Annotation overlay that renders detection results
/// Extracted to be used within the same GeometryReader scope as the detected content
struct AnnotationOverlay: View {
    let observations: [DetectionResult]
    let geometry: GeometryProxy
    let showIdentifiers: Bool
    let animateDetections: Bool

    var body: some View {
        ForEach(Array(observations.enumerated()), id: \.offset) { _, observationGroup in
            ForEach(observationGroup.observations, id: \.uuid) { detection in
                AnnotationViewBuilder(
                    observation: detection,
                    geometry: geometry,
                    params: observationGroup.params,
                    showIdentifiers: showIdentifiers,
                    animateDetections: animateDetections
                )
            }
        }
    }
}
