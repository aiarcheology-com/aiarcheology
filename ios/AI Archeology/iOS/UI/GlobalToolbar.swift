//
//  GlobalToolbar.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 01.11.23.
//

import SwiftUI

struct GlobalToolbarLeading: View {
	@EnvironmentObject var guide: Guide

	var body: some View {
		HStack {
			Button ( action:  {
				guide.togglingSideMenu()
			}, label: { Image(systemName: "cpu").foregroundColor(.gray)})
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
						.foregroundColor(.gray)
						.scaleEffect(isAnimating ? 1.1 : 0.8)
						.onAppear {
							withAnimation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
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
