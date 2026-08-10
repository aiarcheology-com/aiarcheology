//
//  Snapshot.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI
import Combine

typealias SnapshotProvider = @MainActor (UIImage, CGRect) -> Void

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

// Pass the SnapshotRendering port explicitly via the initializer (renderer:).
struct SnapableGroup<Content: View, P>: View where P: Publisher, P.Failure == Never {
	@Environment(\.snapshotProvider) private var snapshotProvider
	private unowned var renderer: any SnapshotRendering

	private let publisher: P
	private var content: Content

	@inlinable init(renderer: any SnapshotRendering, publisher: P, @ViewBuilder content: () -> Content) {
		self.publisher = publisher
		self.content = content()
		self.renderer = renderer
	}

	var body: some View {
		GeometryReader { geometry in
			content
				.onReceive(publisher) { _ in
					let frame = geometry.frame(in: .local)
					LoggingPolicy.debug(
						"[AIA-0587 TRACE] SnapableGroup received trigger frame=\(frame.width)x\(frame.height) providerAttached=\(snapshotProvider != nil)",
						logger: .rendering
					)
					render(in: frame)
				}
				.onAppear {
					let frame = geometry.frame(in: .local)
					LoggingPolicy.debug(
						"[AIA-0587 TRACE] SnapableGroup appeared frame=\(frame.width)x\(frame.height) providerAttached=\(snapshotProvider != nil)",
						logger: .rendering
					)
				}
				.onDisappear {
					LoggingPolicy.debug("[AIA-0587 TRACE] SnapableGroup disappeared", logger: .rendering)
				}
		}
	}

	@MainActor private func render(in frame: CGRect) {
		LoggingPolicy.debug(
			"[AIA-0587 TRACE] SnapableGroup scheduling render",
			logger: .rendering
		)
		Task { [renderer] in
			LoggingPolicy.debug(
				"[AIA-0587 TRACE] SnapableGroup render task started",
				logger: .rendering
			)
			guard let image = await renderer.snapshot() else {
				LoggingPolicy.debug(
					"[AIA-0587 TRACE] SnapableGroup renderer returned nil",
					logger: .rendering
				)
				return
			}
			LoggingPolicy.debug(
				"[AIA-0587 TRACE] SnapableGroup renderer returned image pixels=\(image.size.width)x\(image.size.height) providerAttached=\(snapshotProvider != nil)",
				logger: .rendering
			)
			guard let snapshotProvider else {
				LoggingPolicy.debug(
					"[AIA-0587 TRACE] SnapableGroup dropped image because provider is missing",
					logger: .rendering
				)
				return
			}
			snapshotProvider(image, frame)
			LoggingPolicy.debug(
				"[AIA-0587 TRACE] SnapableGroup delivered image",
				logger: .rendering
			)
		}
	}
}

extension View {
		// The snapshot is made from a view wrapped within SnapableGroup and driven by the group's publisher
	func onSnapshot(perform action: @escaping SnapshotProvider) -> some View {
		environment(\.snapshotProvider, { image, frame in
			LoggingPolicy.debug(
				"[AIA-0587 TRACE] onSnapshot provider invoked image=\(image.size.width)x\(image.size.height) frame=\(frame.width)x\(frame.height)",
				logger: .rendering
			)
			action(image, frame)
		})
	}
}
