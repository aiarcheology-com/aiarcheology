//
//  GlobalToolbar.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 01.11.23.
//

import SwiftUI

struct GlobalToolbarLeading: View {
	@EnvironmentObject var guide: Guide
	@EnvironmentObject var download: Downloader

	@State private var isAnimating = false
	@State private var animationChange = false

	var body: some View {
		HStack {
			Button(action: {
				guide.togglingSideMenu()
			}) {
				if isAnimating {
					Image(systemName: "cpu")
						.foregroundColor(animationChange ? Color.blue : Color.gray)
						.scaleEffect(animationChange ? 1.1 : 1)
						.onAppear {
							withAnimation(Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
								animationChange.toggle()
							}
						}
				} else {
					Image(systemName: "cpu").foregroundColor(.gray)
				}
			}
			.testability(Testability.Button.globalToolbarSideMenu)
		}
		.onReceive(download.$activeDownloads) { newValue in
			isAnimating = newValue.isEmpty.not
			animationChange.toggle()
		}
	}
}

struct GlobalToolbarTrailing: View {
	@EnvironmentObject var guide: Guide
	@State private var isAnimating = false
	@State private var showPopoverAdjustment = false

	var body: some View {
		HStack {
			detectionButton
			adjustmentButton
			settingsButton
		}
	}
	
	// MARK: - Detection Button
	
	@ViewBuilder
	private var detectionButton: some View {
		if guide.ontheflyDetectionEnabled {
			Button(action: {
				guide.ontheflyDetectionTapped()
			}) {
				Image(systemName: "pause")
					.foregroundColor(isAnimating ? Color.blue : Color.gray)
					.scaleEffect(isAnimating ? 1.1 : 1)
					.onAppear {
						withAnimation(Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
							isAnimating.toggle()
						}
					}
			}
			.testability(Testability.Button.globalToolbarPauseDetection)
		} else {
			Button(action: {
				guide.ontheflyDetectionTapped()
			}) {
				Image(systemName: "play")
					.foregroundColor(.gray)
			}
			.testability(Testability.Button.globalToolbarPlayDetection)
		}
	}
	
	// MARK: - Adjustment Button
	
	private var adjustmentButton: some View {
		Button(action: {
			if HostPlatform.current.isiPhone {
				// iPhone: toggle transparent overlay
				guide.showSnapAdjustment.toggle()
			} else {
				// iPad/Mac: use popover (works well in both portrait and landscape)
				showPopoverAdjustment = true
			}
		}) {
			Image(systemName: "pencil.tip.crop.circle")
				.foregroundColor(.gray)
		}
		.testability(Testability.Button.globalToolbarAdjustments)
		.popover(isPresented: $showPopoverAdjustment) {
			SnapAdjustmentView()
				.padding(20)
				.frame(width: 280)
				.environmentObject(guide.snapAdjustment)
		}
	}
	
	// MARK: - Settings Button
	
	private var settingsButton: some View {
		Button(action: {
			guide.settingsTapped()
		}) {
			Image(systemName: "gearshape")
				.foregroundColor(.gray)
		}
		.testability(Testability.Button.globalToolbarSettings)
	}
}
