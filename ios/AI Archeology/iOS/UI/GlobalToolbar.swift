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

	var body: some View {
		HStack {
			Button ( action:  { }, label: { Image(systemName: "play").foregroundColor(.gray)})
			Button ( action:  { }, label: { Image(systemName: "pencil.tip.crop.circle").foregroundColor(.gray)})
			Button ( action:  { }, label: { Image(systemName: "person").foregroundColor(.gray)})
		}
	}
}
