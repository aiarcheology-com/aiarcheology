//
//  GlobalToolbar.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 01.11.23.
//

import SwiftUI

struct GlobalToolbarLeading: View {
	@EnvironmentObject var chromeState: AppChromeState
	@EnvironmentObject var download: Downloader

	@State private var isAnimating = false
	@State private var animationChange = false

	var body: some View {
		HStack {
			Button(action: {
				chromeState.togglingSideMenu()
			}) {
				if isAnimating {
					Image(systemName: "cpu")
						.foregroundColor(animationChange ? Color.blue : Color.gray)
						.scaleEffect(animationChange ? 1.1 : 1)
						// Value-scoped: `withAnimation(.repeatForever)` in onAppear
						// leaks the forever animation into unrelated layout
						// changes of the same transaction (the chrome show/hide
						// transition kept oscillating — AIA-0011 review finding).
						.animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: animationChange)
						.onAppear {
							animationChange.toggle()
						}
				} else {
					Image(systemName: "cpu").foregroundColor(.gray)
				}
			}
			.testability(Testability.Button.globalToolbarSideMenu)
			.tourTarget(.modelsButton)
		}
		.onReceive(download.$activeDownloads) { newValue in
			isAnimating = newValue.isEmpty.not
			animationChange.toggle()
		}
	}
}

struct GlobalToolbarTrailing: View {
	@EnvironmentObject var chromeState: AppChromeState
	@EnvironmentObject var detectionState: DetectionSessionState
	@State private var isAnimating = false
	@State private var showPopoverAdjustment = false

	var body: some View {
		// Explicit spacing and 44pt minimum frames: the bare SF Symbol buttons
		// measure as small as 19x36pt with an 8pt gap, below the recommended
		// hit-target size, and sat visibly cramped on Dynamic Island devices.
		HStack(spacing: 16) {
			// Find lives in the top bar in normal mode on every device (AIA-0294); in
			// fullscreen the bar is hidden, so it moves to the floating capsule instead.
			findButton
			detectionButton
			// Always available: users adjust brightness/contrast/saturation
			// of the content also while no detection runs.
			adjustmentButton
		}
	}

	// MARK: - Find Button

	/// Starts the store-a-finding pick mode: the next tap on the content marks
	/// the place to store (works with or without detection running).
	private var findButton: some View {
		Button(action: {
			chromeState.findTapped()
		}) {
			Image(systemName: "plus.viewfinder")
				.foregroundColor(.gray)
				.frame(minWidth: 44, minHeight: 44)
				.contentShape(Rectangle())
		}
		.accessibilityLabel(L10n.Finding.Save.title)
		.testability(Testability.Button.globalToolbarFind)
		.tourTarget(.findButton)
	}
	
	// MARK: - Detection Button
	
	@ViewBuilder
	private var detectionButton: some View {
		if detectionState.ontheflyDetectionEnabled {
			Button(action: {
				detectionState.ontheflyDetectionTapped()
			}) {
				Image(systemName: "pause")
					.foregroundColor(isAnimating ? Color.blue : Color.gray)
					.scaleEffect(isAnimating ? 1.1 : 1)
					// Value-scoped for the same reason as the leading cpu icon.
					.animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isAnimating)
					.onAppear {
						isAnimating.toggle()
					}
					.frame(minWidth: 44, minHeight: 44)
					.contentShape(Rectangle())
			}
			.testability(Testability.Button.globalToolbarPauseDetection)
		} else {
			Button(action: {
				detectionState.ontheflyDetectionTapped()
			}) {
				Image(systemName: "play")
					.foregroundColor(.gray)
					.frame(minWidth: 44, minHeight: 44)
					.contentShape(Rectangle())
			}
			.testability(Testability.Button.globalToolbarPlayDetection)
			.tourTarget(.playButton)
		}
	}
	
	// MARK: - Adjustment Button
	
	private var adjustmentButton: some View {
		Button(action: {
			if HostPlatform.current.isiPhone {
				// iPhone: toggle transparent overlay
				detectionState.showSnapAdjustment.toggle()
			} else {
				// iPad/Mac: use popover (works well in both portrait and landscape)
				showPopoverAdjustment = true
			}
		}) {
			Image(systemName: "pencil.tip.crop.circle")
				.foregroundColor(.gray)
				.frame(minWidth: 44, minHeight: 44)
				.contentShape(Rectangle())
		}
		.testability(Testability.Button.globalToolbarAdjustments)
		.popover(isPresented: $showPopoverAdjustment) {
			SnapAdjustmentView()
				.padding(20)
				.frame(width: 280)
				.environmentObject(detectionState.snapAdjustment)
		}
	}
}
