//
//  Snapshot.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI
import Combine

typealias SnapshotProvider = @MainActor (UIImage, CGRect, SnapshotRequest) -> Void

struct Snapshot {
    let image: UIImage
    let date: Date = Date()
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
		let deliver: SnapshotProvider
	}

	private struct Work {
		let request: SnapshotRequest
		let consumer: Consumer
		let attachmentGeneration: UInt64
		let captureGeneration: UInt64
	}

	private let renderer: any SnapshotRendering
	private var consumer: Consumer?
	private var pendingRequest: SnapshotRequest?
	private var latestRequest: SnapshotRequest?
	private var consumerGeneration: UInt64 = 0
	private var attachmentGeneration: UInt64 = 0
	private var captureGeneration: UInt64 = 0
	private var rendererAttached = false
	private var rendering = false
	private var captureActive = false

	init(renderer: any SnapshotRendering) {
		self.renderer = renderer
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

	func registerConsumer(id: UUID, frame: CGRect, deliver: @escaping SnapshotProvider) {
		consumerGeneration &+= 1
		consumer = Consumer(id: id, generation: consumerGeneration, frame: frame, deliver: deliver)
		// SwiftUI can replace this view while the physical WebKit continuation is still alive. The
		// old completion belongs to the departed consumer, so re-offer the latest request to the
		// replacement after it returns rather than waiting for an unrelated user gesture/timer tick.
		if rendering, let latestRequest {
			pendingRequest = latestRequest
		}
		startNextIfPossible()
	}

	func updateConsumer(id: UUID, frame: CGRect, deliver: @escaping SnapshotProvider) {
		guard consumer?.id == id else { return }
		consumerGeneration &+= 1
		consumer = Consumer(id: id, generation: consumerGeneration, frame: frame, deliver: deliver)
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

		pendingRequest = nil
		rendering = true
		let work = Work(
			request: request,
			consumer: consumer,
			attachmentGeneration: attachmentGeneration,
			captureGeneration: captureGeneration
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
			work.consumer.deliver(image, work.consumer.frame, work.request)
		}
		startNextIfPossible()
	}
}

// Pass the persistent snapshot-work coordinator explicitly via the initializer.
struct SnapableGroup<Content: View, P>: View where P: Publisher, P.Failure == Never, P.Output == SnapshotRequest {
	@Environment(\.snapshotProvider) private var snapshotProvider
	private unowned var workCoordinator: SnapshotWorkCoordinator

	private let publisher: P
	private var content: Content
	@State private var consumerID = UUID()

	@inlinable init(workCoordinator: SnapshotWorkCoordinator, publisher: P, @ViewBuilder content: () -> Content) {
		self.publisher = publisher
		self.content = content()
		self.workCoordinator = workCoordinator
	}

	var body: some View {
		GeometryReader { geometry in
			content
				.onReceive(publisher) { request in
					workCoordinator.enqueue(request)
				}
				.onAppear {
					workCoordinator.registerConsumer(
						id: consumerID,
						frame: geometry.frame(in: .local),
						deliver: snapshotProvider ?? { _, _, _ in }
					)
				}
				.onChange(of: geometry.size) { _, _ in
					workCoordinator.updateConsumer(
						id: consumerID,
						frame: geometry.frame(in: .local),
						deliver: snapshotProvider ?? { _, _, _ in }
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
		environment(\.snapshotProvider, { image, frame, request in
			action(image, frame, request)
		})
	}
}
