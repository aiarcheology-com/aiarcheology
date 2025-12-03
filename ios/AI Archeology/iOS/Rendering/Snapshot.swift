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


// Do not forget to initiate a custom renderer, e.g. .environmentObject(customRenderer)
// when wrapping another View
struct SnapableGroup<Content: View, P>: View where P: Publisher, P.Failure == Never {
	@Environment(\.snapshotProvider) private var snapshotProvider
	private unowned var renderer: DefaultRenderer

	private let publisher: P
	private var content: Content

	@inlinable init(renderer: DefaultRenderer, publisher: P, @ViewBuilder content: () -> Content) {
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
		renderer.render(content) { image, error in
			if let image = image, error == nil {
				snapshotProvider?(image, frame)
			} else {
					//TODO: Handle error
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
		// The snapshot is made from a complete view and driven by an explicit publisher
	func onSnapshot<P>(_ publisher: P, perform action: @escaping (UIImage) -> Void) -> some View where P : Publisher, P.Failure == Never {
		self.onReceive(publisher) { _ in
			Task { @MainActor in
				@Environment(\.displayScale) var displayScale
				let renderer = ImageRenderer(content: self)
				renderer.scale = displayScale
				renderer.isOpaque = false
				if let uiImage = renderer.uiImage {
					action(uiImage)
				}
			}
		}
	}
}
