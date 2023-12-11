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

		Slide(imageName: "AppLogo", title: "Welcome to ML Browser", description: "The application combines the browsing experience with assisted object detection within web content.", showButton: true, ratio: 0.4, arrows: [.right]),
		Slide(imageName: "slide0", title: "Open a Web Page", description: "You can open any web page, similar to how you would in a web browser, with content you wish to test using your object detection model."),
		Slide(imageName: "slide1", title: "Pick an address from the browsing history", description: "A long tap on the address bar opens a dropdown menu showing your browsing history."),
		Slide(imageName: "slide2", title: "Add a New Model", description: "The application is capable of working with Create ML detection models. Click the processor icon in the top left corner, and then plus sign to add a new model."),
		Slide(imageName: "slide3", title: "Tap on the Icon to Open the File", description: "You can download any Create ML detection model to your Apple device and load it into the ML Browser app. The ML Browser does not send your model anywhere, or collect information. The model is used only for the annotations."),
		Slide(imageName: "slide4", title: "Activate the Models", description: "In this menu on the left, you can activate any detection model. These detectors work simultaneously on the same web page content."),
		Slide(imageName: "slide5", title: "Change the Model's Annotation Options", description: "When you select a model from the left menu, you can adjust various annotation options."),
		Slide(imageName: "slide6", title: "Adjust Screen Image Properties", description: "In some cases, you can aid the detector by altering the browser's rendering properties, such as brightness and contrast."),
		Slide(imageName: "slide7", title: "Hit the Play Button", description: "After hitting the button, the detectors start to label the web content."),
		Slide(imageName: "slide8", title: "Annotation", description: "Now, you can browse your favorite web content and look for features that your detection model might recognize.", showButton: true, arrows: [.left])
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
								}
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
								}
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
							Toggle("Show next time", isOn: $settings.keepSlideShowActive)
								.padding(40)
						}
					}
					.frame(width: geometry.size.width, height: geometry.size.height)
					.cornerRadius(15)
					.shadow(radius: 10)
				}
			}
			.tabViewStyle(PageTabViewStyle())
			.indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
		}
	}
}
