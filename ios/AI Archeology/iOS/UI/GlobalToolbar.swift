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

		// State variable for the animation
	@State private var isAnimating = false

	var body: some View {
		HStack {
			Button(action: {
				guide.togglingSideMenu()
			}) {
				Image(systemName: "cpu")
					.foregroundColor(isAnimating ? Color.blue : Color.gray)
					.scaleEffect(isAnimating ? 1.1 : 1)
					.animation(Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isAnimating)
			}
		}
		.onReceive(download.$activeDownloads) { newValue in
			if download.activeDownloads.isEmpty.not {
				isAnimating.toggle()
			}
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
				.disabled(showPopoverAdjustment)
			} else {
				Button(action: {
					guide.ontheflyDetectionTapped()
				}) {
					Image(systemName: "play")
						.foregroundColor(.gray)
				}
				.disabled(showPopoverAdjustment)
			}
			Button ( action:  {
				showPopoverAdjustment = true
			}) {
				Image(systemName: "pencil.tip.crop.circle")
					.foregroundColor(.gray)
			}
			// TODO: use this https://pspdfkit.com/blog/2022/presenting-popovers-on-iphone-with-swiftui/
			.popover(isPresented: $showPopoverAdjustment) {
				SnapAdjustmentView()
					.padding(20)
					.frame(width: 280)
					.onDisappear {
						showPopoverAdjustment = false
					}
					.environmentObject(guide.appState.snapAdjustment)
			}
			Button ( action:  {
				guide.settingsTapped()
			}) {
				Image(systemName: "gearshape")
					.foregroundColor(.gray)
			}
			.disabled(showPopoverAdjustment)
		}
	}
}
