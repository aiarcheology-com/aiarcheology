//
//  Slide.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 04.12.23.
//

import SwiftUI

enum Arrows {
	case left
	case right
	case none
}

struct Slide {
	var imageName: String
	var title: String
	var description: String
	var showButton: Bool = false
	var ratio: Double = 0.6
	var arrows: [Arrows] = [.left, .right]

}

struct SlideshowView: View {
	@EnvironmentObject var settings: Settings
	private let slides: [Slide] = [
		Slide(imageName: "AppLogo", title: L10n.Slideshow.Slide0.title, description: L10n.Slideshow.Slide0.description, showButton: true, ratio: 0.4, arrows: [.right]),
		Slide(imageName: "slide0", title: L10n.Slideshow.Slide1.title, description: L10n.Slideshow.Slide1.description),
		Slide(imageName: "slide1", title: L10n.Slideshow.Slide2.title, description: L10n.Slideshow.Slide2.description),
		Slide(imageName: "slide2", title: L10n.Slideshow.Slide3.title, description: L10n.Slideshow.Slide3.description),
		Slide(imageName: "slide3", title: L10n.Slideshow.Slide4.title, description: L10n.Slideshow.Slide4.description),
		Slide(imageName: "slide4", title: L10n.Slideshow.Slide5.title, description: L10n.Slideshow.Slide5.description),
		Slide(imageName: "slide5", title: L10n.Slideshow.Slide6.title, description: L10n.Slideshow.Slide6.description),
		Slide(imageName: "slide6", title: L10n.Slideshow.Slide7.title, description: L10n.Slideshow.Slide7.description),
		Slide(imageName: "slide7", title: L10n.Slideshow.Slide8.title, description: L10n.Slideshow.Slide8.description),
		Slide(imageName: "slide8", title: L10n.Slideshow.Slide9.title, description: L10n.Slideshow.Slide9.description, showButton: true, arrows: [.left])
	]

	var body: some View {
		GeometryReader { geometry in
			TabView {
				ForEach(slides.indices, id: \.self) { index in
					let slide = slides[index]
					VStack {
						Spacer()
						Text(slide.title)
							.font(.title3)
						Spacer()
						HStack {
							Spacer()
							if slide.arrows.contains(.left) {
								Button {
									// go to the left slide
								} label: {
									Image(systemName: "hand.draw")
									.resizable()
									.scaleEffect(x: -1, y: 1)
									.frame(width: 40, height: 40)
									.foregroundColor(.accentColor.opacity(0.5))
									.blur(radius: 0.8)
								}
								.testability(Testability.Button.slideshowSwipeLeft, index: index)
								.padding()
							} else {
								Rectangle()
								.foregroundColor(.clear)
								.frame(width: 70, height: 70)
							}
							Spacer()
							Image(slide.imageName)
							.resizable()
							.aspectRatio(contentMode: .fit)
							.frame(width: geometry.size.width * slide.ratio)
							.cornerRadius(10)
							.shadow(radius: 7)
							Spacer()
							if slide.arrows.contains(.right) {
								Button {
										// go to the right slide
								} label: {
									Image(systemName: "hand.draw")
									.resizable()
									.frame(width: 40, height: 40)
									.foregroundColor(.accentColor.opacity(0.5))
									.blur(radius: 0.8)
								}
								.testability(Testability.Button.slideshowSwipeRight, index: index)
								.padding()
							} else {
								Rectangle()
								.foregroundColor(.clear)
								.frame(width: 70, height: 70)
							}
							Spacer()
						}
						Spacer()
							Text(slide.description)
							.font(.body)
							.padding(50)
						Spacer()
						if slide.showButton {
							Toggle(L10n.Settings.showNextTime, isOn: $settings.keepSlideShowActive)
								.testability(Testability.Toggle.slideshowShowNextTime)
							.padding(40)
						}
					}
					.frame(width: geometry.size.width, height: geometry.size.height)
					.cornerRadius(15)
					.shadow(radius: 10)
					// Per-slide identity for UI tests (the arrow buttons are decorative).
					.testability(Testability.View.slideshowSlide, index: index)
				}
			}
		.tabViewStyle(PageTabViewStyle())
			.indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
		}
		.sheetDismissButton(testability: .slideShowDismiss)
	}
}

struct DescriptinSlideStyle: ShapeStyle {
	func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
		if environment.colorScheme == .light {
			return Color.accentColor.opacity(0.5)
		} else {
			return Color.accentColor.opacity(0.5)
		}
	}
}
