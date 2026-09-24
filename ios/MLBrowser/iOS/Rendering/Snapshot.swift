//
//  Snapshot.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI
import Combine

typealias SnapshotProvider = @MainActor (UIImage, CGRect, SnapshotRequest, SnapshotProvenance) -> Void
/// Reads the web view's current ``CaptureContext`` (AIA-0846); `nil` when none is attached.
typealias CaptureContextProvider = @MainActor () -> CaptureContext?

/// Which document a delivered snapshot came from (AIA-0846).
///
/// The context is read synchronously before `takeSnapshot` starts and again when it returns.
/// Detection still receives every image — refusing the ones taken while a map rewrote its URL
/// would leave the boxes blank for a whole timer period after each pan — but a finding may only be
/// made from an image whose source is established, so the verdict travels with it.
struct SnapshotProvenance: Equatable {
	/// The context read when the snapshot started, or `nil` when the document itself is unknown:
	/// none was attached at either reading, or a different document was by the end.
	let context: CaptureContext?
	/// Whether nothing at all changed while the image was being taken. `false` with a non-nil
	/// context means the same document, whose URL or map frames moved mid-snapshot.
	let isCoherent: Bool

	/// A snapshot with no known source. The default for frames built outside the snapshot
	/// pipeline (tests), so a finding can never treat an unproven image as established.
	static let unknown = SnapshotProvenance(context: nil, isCoherent: false)

	static func between(start: CaptureContext?, end: CaptureContext?) -> SnapshotProvenance {
		guard let start, let end, start.documentRevision == end.documentRevision else { return .unknown }
		return SnapshotProvenance(context: start, isCoherent: start == end)
	}
}
typealias SnapshotRequestAcceptance = @MainActor @Sendable (SnapshotRequest) -> Bool

struct Snapshot {
    let image: UIImage
    let date: Date = Date()
}

/// Filters a `CurrentValueSubject` replay caused by an ordinary SwiftUI body update. The same
/// mounted `SnapableGroup` must enqueue a request only once. A fresh group gets a fresh coordinator
/// and therefore still receives the retained start request after it mounts.
@MainActor
final class SnapshotRequestReplayCoordinator: ObservableObject {
	private var lastAcceptedRequest: SnapshotRequest?

	func accepts(_ request: SnapshotRequest) -> Bool {
		guard lastAcceptedRequest != request else { return false }
		lastAcceptedRequest = request
		return true
	}
}

struct SnapshotRendererKey: EnvironmentKey {
	static let defaultValue: SnapshotProvider? = nil
}

extension EnvironmentValues {
	var snapshotProvider: SnapshotProvider? {
		get { self[SnapshotRendererKey.self] }
		set { self[SnapshotRendererKey.self] = newValue }
	}
}

/// Coordinates snapshot requests across SwiftUI replacement. A request is retained until both a
/// consumer and live WKWebView have attached, and only one physical WebKit snapshot is outstanding
/// at a time. Newer requests coalesce; a completion is delivered only to the exact consumer/frame
/// and WebView/capture generation that started it.
@MainActor
final class SnapshotWorkCoordinator {
	private struct Consumer {
		let id: UUID
		let generation: UInt64
		let frame: CGRect
		let acceptsRequest: SnapshotRequestAcceptance
		let deliver: SnapshotProvider
	}

	private struct Work {
		let request: SnapshotRequest
		let consumer: Consumer
		let attachmentGeneration: UInt64
		let captureGeneration: UInt64
		/// The capture context when the physical snapshot started (AIA-0846).
		let startContext: CaptureContext?
	}

	private let renderer: any SnapshotRendering
	private let captureContext: CaptureContextProvider
	private var consumer: Consumer?
	private var pendingRequest: SnapshotRequest?
	private var latestRequest: SnapshotRequest?
	private var consumerGeneration: UInt64 = 0
	private var attachmentGeneration: UInt64 = 0
	private var captureGeneration: UInt64 = 0
	private var rendererAttached = false
	private var rendering = false
	private var captureActive = false

	/// - Parameter captureContext: required rather than defaulted, so a composition that forgets to
	///   wire the browser cannot compile into one whose every frame has an unknown source.
	init(renderer: any SnapshotRendering, captureContext: @escaping CaptureContextProvider) {
		self.renderer = renderer
		self.captureContext = captureContext
	}

	func rendererDidAttach() {
		attachmentGeneration &+= 1
		rendererAttached = true
		// `takeSnapshot` belongs to the WebView that was attached when it began. If recovery
		// attaches a replacement before that continuation returns, discard the old-page image and
		// run the latest request against the replacement instead.
		if rendering, let latestRequest {
			pendingRequest = latestRequest
		}
		startNextIfPossible()
	}

	func registerConsumer(
		id: UUID,
		frame: CGRect,
		acceptsRequest: @escaping SnapshotRequestAcceptance,
		deliver: @escaping SnapshotProvider
	) {
		consumerGeneration &+= 1
		consumer = Consumer(
			id: id,
			generation: consumerGeneration,
			frame: frame,
			acceptsRequest: acceptsRequest,
			deliver: deliver
		)
		// SwiftUI can replace this view while the physical WebKit continuation is still alive. The
		// old completion belongs to the departed consumer, so re-offer the latest request to the
		// replacement after it returns rather than waiting for an unrelated user gesture/timer tick.
		if rendering, let latestRequest {
			pendingRequest = latestRequest
		}
		startNextIfPossible()
	}

	func updateConsumer(
		id: UUID,
		frame: CGRect,
		acceptsRequest: @escaping SnapshotRequestAcceptance,
		deliver: @escaping SnapshotProvider
	) {
		guard consumer?.id == id else { return }
		consumerGeneration &+= 1
		consumer = Consumer(
			id: id,
			generation: consumerGeneration,
			frame: frame,
			acceptsRequest: acceptsRequest,
			deliver: deliver
		)
		// A snapshot that began against the old geometry must not be applied. Re-request the latest
		// live input after its continuation returns; overlapping WKWebView.takeSnapshot calls are
		// intentionally forbidden.
		if rendering, let latestRequest {
			pendingRequest = latestRequest
		}
		startNextIfPossible()
	}

	func unregisterConsumer(id: UUID) {
		guard consumer?.id == id else { return }
		consumer = nil
	}

	/// Freezes snapshot delivery while the finding picker/save sheet owns the displayed frame.
	/// An existing WebKit continuation cannot be cancelled, so its generation is invalidated and
	/// any request that arrived before the freeze is discarded. Detection resumes with a fresh
	/// timer request after the capture closes.
	func findingCaptureStarted() {
		captureActive = true
		captureGeneration &+= 1
		pendingRequest = nil
		latestRequest = nil
	}

	func findingCaptureEnded() {
		captureActive = false
	}

	func enqueue(_ request: SnapshotRequest) {
		guard captureActive.not else { return }
		latestRequest = request
		pendingRequest = request
		startNextIfPossible()
	}

	private func startNextIfPossible() {
		guard rendering.not,
			  captureActive.not,
			  rendererAttached,
			  let request = pendingRequest,
			  let consumer
		else { return }
		// A request can wait here while SwiftUI replaces the consumer or WebKit attaches. Re-check the
		// session at the physical-work boundary so a request invalidated by pause/reset never starts an
		// expensive capture merely because those dependencies appeared later.
		guard consumer.acceptsRequest(request) else {
			pendingRequest = nil
			latestRequest = nil
			return
		}

		pendingRequest = nil
		rendering = true
		let work = Work(
			request: request,
			consumer: consumer,
			attachmentGeneration: attachmentGeneration,
			captureGeneration: captureGeneration,
			startContext: captureContext()
		)
		let renderer = renderer
		Task { @MainActor [weak self, renderer] in
			let image = await renderer.snapshot()
			self?.finished(work, image: image)
		}
	}

	private func finished(_ work: Work, image: UIImage?) {
		rendering = false
		if let image,
		   consumer?.id == work.consumer.id,
		   consumer?.generation == work.consumer.generation,
		   attachmentGeneration == work.attachmentGeneration,
		   captureGeneration == work.captureGeneration {
			// Read at the same main-actor turn the image is handed over, so nothing can change between
			// the verdict and the delivery.
			let provenance = SnapshotProvenance.between(start: work.startContext, end: captureContext())
			work.consumer.deliver(image, work.consumer.frame, work.request, provenance)
		}
		startNextIfPossible()
	}
}

// Pass the persistent snapshot-work coordinator explicitly via the initializer.
struct SnapableGroup<Content: View, P>: View where P: Publisher, P.Failure == Never, P.Output == SnapshotRequest {
	@Environment(\.snapshotProvider) private var snapshotProvider
	private unowned var workCoordinator: SnapshotWorkCoordinator

	private let publisher: P
	private let acceptsRequest: SnapshotRequestAcceptance
	private var content: Content
	@State private var consumerID = UUID()
	@StateObject private var replayCoordinator = SnapshotRequestReplayCoordinator()

	@inlinable init(
		workCoordinator: SnapshotWorkCoordinator,
		publisher: P,
		acceptsRequest: @escaping SnapshotRequestAcceptance,
		@ViewBuilder content: () -> Content
	) {
		self.publisher = publisher
		self.acceptsRequest = acceptsRequest
		self.content = content()
		self.workCoordinator = workCoordinator
	}

	var body: some View {
		GeometryReader { geometry in
			content
				.onReceive(publisher) { request in
					guard replayCoordinator.accepts(request) else { return }
					workCoordinator.enqueue(request)
				}
				.onAppear {
					workCoordinator.registerConsumer(
						id: consumerID,
						frame: geometry.frame(in: .local),
						acceptsRequest: acceptsRequest,
						deliver: snapshotProvider ?? { _, _, _, _ in }
					)
				}
				.onChange(of: geometry.size) { _, _ in
					workCoordinator.updateConsumer(
						id: consumerID,
						frame: geometry.frame(in: .local),
						acceptsRequest: acceptsRequest,
						deliver: snapshotProvider ?? { _, _, _, _ in }
					)
				}
				.onDisappear {
					workCoordinator.unregisterConsumer(id: consumerID)
				}
		}
	}
}

extension View {
		// The snapshot is made from a view wrapped within SnapableGroup and driven by the group's publisher
	func onSnapshot(perform action: @escaping SnapshotProvider) -> some View {
		environment(\.snapshotProvider, { image, frame, request, provenance in
			action(image, frame, request, provenance)
		})
	}
}
