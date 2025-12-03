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
				.disabled(showPopoverAdjustment)
			} else {
				Button(action: {
					guide.ontheflyDetectionTapped()
				}) {
					Image(systemName: "play")
						.foregroundColor(.gray)
				}
				.testability(Testability.Button.globalToolbarPlayDetection)
				.disabled(showPopoverAdjustment)
			}
			Button ( action:  {
				showPopoverAdjustment = true
			}) {
				Image(systemName: "pencil.tip.crop.circle")
					.foregroundColor(.gray)
			}
			.testability(Testability.Button.globalToolbarAdjustments)
			// TODO: use this https://pspdfkit.com/blog/2022/presenting-popovers-on-iphone-with-swiftui/
			.popover(isPresented: $showPopoverAdjustment) {
				SnapAdjustmentView()
					.padding(20)
					.frame(width: 280)
					.onDisappear {
						showPopoverAdjustment = false
					}
					.environmentObject(guide.snapAdjustment)
			}
			Button ( action:  {
				guide.settingsTapped()
			}) {
				Image(systemName: "gearshape")
					.foregroundColor(.gray)
			}
			.testability(Testability.Button.globalToolbarSettings)
			.disabled(showPopoverAdjustment)
		}
	}
}
