//
//  Slide.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 04.12.23.
//

import SwiftUI

struct Slide {
	var imageName: String
	var title: String
	var description: String
	var showButton: Bool = false
	var ratio: Double = 0.6
}


struct SlideshowView: View {
	@EnvironmentObject var settings: Settings
	private let slides: [Slide] = [

		Slide(imageName: "AppLogo", title: "Welcome to ML Browser", description: "The application combines the browsing experience with assisted object detection within web content.", showButton: true, ratio: 0.4),
		Slide(imageName: "slide0", title: "Open a Web Page", description: "You can open any web page, similar to how you would in a web browser, with content you wish to test using your object detection model."),
		Slide(imageName: "slide1", title: "Add a New Model", description: "The application is capable of working with Create ML models. Click the plus sign to add one."),
		Slide(imageName: "slide2", title: "Tap on the Icon to Open the File", description: "You can download any Create ML detection model to your Apple device and load it into the ML Browser app."),
		Slide(imageName: "slide3", title: "Activate the Models", description: "In this menu on the left, you can activate any detection model. These detectors work simultaneously on the same web page content."),
		Slide(imageName: "slide4", title: "Change the Model's Annotation Options", description: "When you select a model from the left menu, you can adjust various annotation options."),
		Slide(imageName: "slide5", title: "Adjust Screen Image Properties", description: "In some cases, you can aid the detector by altering the browser's rendering properties, such as brightness and contrast."),
		Slide(imageName: "slide6", title: "Annotation", description: "Now, you can browse your favorite web content and look for features that your detection model might recognize.", showButton: true)
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
						Image(slide.imageName)
							.resizable()
							.aspectRatio(contentMode: .fit)
							.frame(width: geometry.size.width * slide.ratio)
							.cornerRadius(10)
							.shadow(radius: 7)
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
		}
	}
}
