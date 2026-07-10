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
					render(in: geometry.frame(in: .local))
				}
		}
	}

	@MainActor private func render(in frame: CGRect) {
		Task { [renderer] in
			if let image = await renderer.snapshot() {
				snapshotProvider?(image, frame)
			}
		}
	}
}

extension View {
		// The snapshot is made from a view wrapped within SnapableGroup and driven by the group's publisher
	func onSnapshot(perform action: @escaping SnapshotProvider) -> some View {
		environment(\.snapshotProvider, { image, frame in
			action(image, frame)
		})
	}
}
