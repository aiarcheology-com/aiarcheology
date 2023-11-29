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
			} else {
				Button(action: {
					guide.ontheflyDetectionTapped()
				}) {
					Image(systemName: "play")
						.foregroundColor(.gray)
				}
			}
			Button ( action:  { }) {
				Image(systemName: "pencil.tip.crop.circle")
					.foregroundColor(.gray)
			}
			Button ( action:  {
				guide.settingsTapped()
			}) {
				Image(systemName: "gearshape")
					.foregroundColor(.gray)
			}
		}
	}
}
