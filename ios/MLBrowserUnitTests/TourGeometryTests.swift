import XCTest
import SwiftUI
@testable import ML_Browser

// AIA-1014: a native navigation toolbar can host its SwiftUI content separately from the root.
// Exercise live native conversion and verify the SwiftUI toolbar-marker integration.
@MainActor
final class TourGeometryTests: XCTestCase {
	func testSeparateNativeHostsConvertIntoOverlayContentCoordinates() throws {
		let fixture = try NativeGeometryFixture()
		defer { fixture.close() }
		// Toolbar host begins at (20, 70), button at (12, 8); overlay begins below
		// a 30pt title bar. The result must include both hosts, not just button-local bounds.
		XCTAssertEqual(fixture.target.rect(in: fixture.overlay), CGRect(x: 32, y: 48, width: 44, height: 36))
	}

	func testReparentingAndResizingUseLiveGeometryWithoutRepublishingTarget() throws {
		let fixture = try NativeGeometryFixture()
		defer { fixture.close() }
		fixture.toolbar.frame.origin = CGPoint(x: 50, y: 90)
		XCTAssertEqual(fixture.target.rect(in: fixture.overlay), CGRect(x: 62, y: 68, width: 44, height: 36))
		// Simulate a toolbar host replaced by window relayout / Settings replay.
		fixture.container.addSubview(fixture.button)
		fixture.button.frame = CGRect(x: 100, y: 12, width: 52, height: 40)
		XCTAssertEqual(fixture.target.rect(in: fixture.overlay), fixture.button.frame)
		fixture.container.bounds.size.width = 120
		XCTAssertNil(fixture.target.rect(in: fixture.overlay), "A partly off-window control is not a usable cutout")
		fixture.container.bounds.size.width = 800
		XCTAssertNotNil(fixture.target.rect(in: fixture.overlay))
	}

	func testDetachedAndReattachedTargetsDoNotReuseStaleCoordinates() throws {
		let fixture = try NativeGeometryFixture()
		defer { fixture.close() }
		XCTAssertNotNil(fixture.target.rect(in: fixture.overlay))
		fixture.button.removeFromSuperview()
		XCTAssertNil(fixture.target.rect(in: fixture.overlay))
		fixture.toolbar.addSubview(fixture.button)
		XCTAssertNotNil(fixture.target.rect(in: fixture.overlay))
	}

	func testHiddenAncestorAndEmptyTargetsAreUnavailable() throws {
		let fixture = try NativeGeometryFixture()
		defer { fixture.close() }
		fixture.toolbar.isHidden = true
		XCTAssertNil(fixture.target.rect(in: fixture.overlay))
		fixture.toolbar.isHidden = false
		XCTAssertNotNil(fixture.target.rect(in: fixture.overlay))
		fixture.button.bounds.size = .zero
		XCTAssertNil(fixture.target.rect(in: fixture.overlay))
	}

	func testTargetInAnotherWindowCannotDriveThisOverlay() throws {
		let fixture = try NativeGeometryFixture()
		let other = try NativeGeometryFixture()
		defer { fixture.close(); other.close() }
		XCTAssertNil(fixture.target.rect(in: other.overlay))
	}

	func testOverlayBoundsOriginIsNormalizedToDrawingCoordinates() throws {
		let fixture = try NativeGeometryFixture()
		defer { fixture.close() }
		fixture.container.bounds.origin = CGPoint(x: 5, y: 10)
		XCTAssertEqual(fixture.target.rect(in: fixture.overlay), CGRect(x: 32, y: 48, width: 44, height: 36))
	}

	func testNativeHostTransformIsIncludedInTargetPosition() throws {
		let fixture = try NativeGeometryFixture()
		defer { fixture.close() }
		fixture.toolbar.transform = CGAffineTransform(translationX: 30, y: 20)
		XCTAssertEqual(fixture.target.rect(in: fixture.overlay), CGRect(x: 62, y: 68, width: 44, height: 36))
	}

	func testReferenceDoesNotRetainRemovedNativeView() {
		let reference = TourTargetReference()
		var view: UIView? = UIView()
		reference.view = view
		view = nil
		XCTAssertNil(reference.view)
	}

	func testNativeToolbarTargetMatchesButtonPosition() async throws {
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
		let measurements = TourGeometryMeasurements()
		let host = UIHostingController(rootView: TourGeometryFixture(measurements: measurements))
		let window = UIWindow(windowScene: scene)
		window.rootViewController = host
		window.isHidden = false
		defer {
			window.isHidden = true
			window.rootViewController = nil
		}
		let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
			MainActor.assumeIsolated {
				measurements.rect != nil && measurements.target?.window != nil && measurements.overlay?.window != nil
			}
		}, object: nil)
		await fulfillment(of: [ready], timeout: 10)
		let target = try XCTUnwrap(measurements.target)
		let overlay = try XCTUnwrap(measurements.overlay)
		let actual = try XCTUnwrap(measurements.rect)
		let expected = target.convert(target.bounds, to: overlay)
		XCTAssertGreaterThan(expected.width, 0)
		XCTAssertEqual(actual.midX, expected.midX, accuracy: 1, "resolved=\(actual), UIKit=\(expected)")
		XCTAssertEqual(actual.midY, expected.midY, accuracy: 1, "resolved=\(actual), UIKit=\(expected)")
	}
}

@MainActor
private final class TourGeometryMeasurements {
	var rect: CGRect?
	var target: UIView?
	let overlayReference = TourTargetReference()
	var overlay: UIView? { overlayReference.view }
}

private struct TourGeometryFixture: View {
	let measurements: TourGeometryMeasurements

	var body: some View {
		NavigationStack {
			Color.gray
				.toolbar {
					ToolbarItem(placement: .navigationBarLeading) {
						Button(action: {}) { Image(systemName: "cpu") }
							.background(TourGeometryProbe { measurements.target = $0 })
							.tourTarget(.modelsButton)
					}
				}
		}
		.overlayPreferenceValue(TourTargetPreferenceKey.self) { targets in
			GeometryReader { _ in
				TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
					let rect = targets[.modelsButton]?.rect(in: measurements.overlayReference)
					Color.clear
						.onChange(of: rect, initial: true) { _, value in measurements.rect = value }
				}
				.background(TourGeometryMarker(reference: measurements.overlayReference))
			}
			.ignoresSafeArea()
		}
	}
}

private struct TourGeometryProbe: UIViewRepresentable {
	let receive: (UIView) -> Void
	func makeUIView(context: Context) -> UIView {
		let view = UIView()
		view.isUserInteractionEnabled = false
		receive(view)
		return view
	}
	func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Real UIKit hosts with deliberately different origins, matching a native toolbar and root overlay.
@MainActor
private final class NativeGeometryFixture {
	let window: UIWindow
	let toolbar = UIView(frame: CGRect(x: 20, y: 70, width: 300, height: 60))
	let container = UIView(frame: CGRect(x: 0, y: 30, width: 800, height: 600))
	let button = UIView(frame: CGRect(x: 12, y: 8, width: 44, height: 36))
	let target = TourTargetReference()
	let overlay = TourTargetReference()

	init() throws {
		let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
		window = UIWindow(windowScene: scene)
		let root = UIViewController()
		window.rootViewController = root
		window.isHidden = false
		root.view.addSubview(toolbar)
		root.view.addSubview(container)
		toolbar.addSubview(button)
		target.view = button
		overlay.view = container
	}

	func close() {
		window.isHidden = true
		window.rootViewController = nil
	}
}
