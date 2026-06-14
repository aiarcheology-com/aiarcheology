//
//  FloatingNavBar.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 11.06.26.
//

import SwiftUI

/// A movable, semi-transparent back | reload/stop | forward capsule for compact widths,
/// where the top bar has no room for navigation buttons. Same interaction pattern as
/// `FloatingChromeButton`: only the capsule's own frame is hit-testable, the drag engages
/// after 10 pt of movement, still touches fall through to the per-icon taps.
struct FloatingNavBar: View {
	@EnvironmentObject var browserState: BrowserState
	@Binding var position: CGPoint?
	/// Find joins the capsule only in fullscreen, where the top bar (and its Find button)
	/// are hidden. In normal mode the capsule is back/reload/forward only (AIA-0294).
	let showsFind: Bool
	/// Starts the store-a-finding pick mode (used when Find lives in the capsule).
	let onFind: () -> Void

	@GestureState private var dragOffset: CGSize = .zero

	private static let height: CGFloat = 52
	private static let itemWidth: CGFloat = 56
	private static let margin: CGFloat = 16
	private static let coordinateSpace = "floatingNavBarArea"

	private var itemCount: CGFloat { showsFind ? 4 : 3 }
	private var barWidth: CGFloat { itemCount * Self.itemWidth }

	var body: some View {
		GeometryReader { geometry in
			HStack(spacing: 0) {
				navItem(
					systemImage: "chevron.left",
					enabled: browserState.canGoBack,
					label: L10n.Browser.Navigation.back,
					testability: .floatingNavBack
				) {
					browserState.goBackTapped()
				}
				reloadStopItem
				navItem(
					systemImage: "chevron.right",
					enabled: browserState.canGoForward,
					label: L10n.Browser.Navigation.forward,
					testability: .floatingNavForward
				) {
					browserState.goForwardTapped()
				}
				if showsFind {
					navItem(
						systemImage: "plus.viewfinder",
						enabled: true,
						label: L10n.Finding.Save.title,
						testability: .floatingNavFind
					) {
						onFind()
					}
				}
			}
			.frame(width: barWidth, height: Self.height)
			.background(
				// Translucency on the background only — icons keep full opacity so they
				// stay legible over busy web content.
				Capsule()
					.fill(.ultraThinMaterial)
					.opacity(0.7)
			)
			// Border and shadow keep the capsule findable on pages that match the
			// material's tone (same rationale as FloatingChromeButton).
			.overlay(
				Capsule()
					.strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
			)
			.shadow(color: Color.black.opacity(0.3), radius: 6, y: 2)
			.contentShape(Capsule())
			.highPriorityGesture(drag(in: geometry.size))
			.position(displayedPosition(in: geometry.size))
		}
		.coordinateSpace(name: Self.coordinateSpace)
	}

	// MARK: - Items

	private var reloadStopItem: some View {
		// While loading the middle button stops; otherwise it reloads.
		navItem(
			systemImage: browserState.isLoading ? "xmark" : "arrow.clockwise",
			enabled: true,
			label: browserState.isLoading ? L10n.Browser.Navigation.stop : L10n.Browser.Navigation.reload,
			testability: .floatingNavReload
		) {
			if browserState.isLoading {
				browserState.stopTapped()
			} else {
				browserState.reloadTapped()
			}
		}
	}

	private func navItem(
		systemImage: String,
		enabled: Bool,
		label: String,
		testability: Testability.Button,
		action: @escaping () -> Void
	) -> some View {
		// Not a Button — a Button claims the touch and the capsule's drag gesture would
		// rarely win (see FloatingChromeButton).
		Image(systemName: systemImage)
			.font(.system(size: 18, weight: .semibold))
			.foregroundStyle(.primary)
			.opacity(enabled ? 1 : 0.35)
			.frame(width: Self.itemWidth, height: Self.height)
			.contentShape(Rectangle())
			.onTapGesture {
				guard enabled else { return }
				action()
			}
			.accessibilityAddTraits(.isButton)
			// Label before testability: under UI testing the helper overrides the label
			// with the identifier, which tests rely on.
			.accessibilityLabel(label)
			.testability(testability)
	}

	// MARK: - Dragging (FloatingChromeButton pattern)

	private func displayedPosition(in size: CGSize) -> CGPoint {
		let base = clamp(position ?? defaultPosition(in: size), in: size)
		return clamp(CGPoint(x: base.x + dragOffset.width, y: base.y + dragOffset.height), in: size)
	}

	private func drag(in size: CGSize) -> some Gesture {
		DragGesture(minimumDistance: 10, coordinateSpace: .named(Self.coordinateSpace))
			.updating($dragOffset) { value, state, _ in
				state = value.translation
			}
			.onEnded { value in
				let base = clamp(position ?? defaultPosition(in: size), in: size)
				position = clamp(
					CGPoint(x: base.x + value.translation.width, y: base.y + value.translation.height),
					in: size
				)
			}
	}

	/// Bottom-center — distinct from the chrome toggle's bottom-right corner, so the two
	/// floating controls do not stack when both are on screen.
	private func defaultPosition(in size: CGSize) -> CGPoint {
		CGPoint(
			x: size.width / 2,
			y: size.height - Self.height / 2 - Self.margin
		)
	}

	private func clamp(_ point: CGPoint, in size: CGSize) -> CGPoint {
		let halfWidth = barWidth / 2
		let halfHeight = Self.height / 2
		return CGPoint(
			x: min(max(point.x, halfWidth + Self.margin), max(size.width - halfWidth - Self.margin, halfWidth + Self.margin)),
			y: min(max(point.y, halfHeight + Self.margin), max(size.height - halfHeight - Self.margin, halfHeight + Self.margin))
		)
	}
}
