//
//  ContentView.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.08.23.
//

import SwiftUI
import CoreData

struct ContentView: View {
    @State private var website: String = ""

    var body: some View {
        NavigationView {
            List {
                ForEach(1..<10) { index in
                    NavigationLink {
                    } label: {
                        Text("Model \(index)")
                    }
                }
            }

            Image("DemoScene")
                .resizable()
                .scaledToFill() // DemoScene code
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { // <2>
                    ToolbarItem(placement: .principal) {
                        TextField("website url", text: $website)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                }
                .navigationBarItems( trailing:
                                        HStack {
                    Button ( action:  { }, label: { Image(systemName: "play")})
                    Button ( action:  { }, label: { Image(systemName: "pencil.tip.crop.circle")})
                    Button ( action:  { }, label: { Image(systemName: "person")})
                }
                )
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
