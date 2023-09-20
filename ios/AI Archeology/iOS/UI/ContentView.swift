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
        NavigationStack {
            TabView {
                ZStack {
                    
                    EmptyView()
                        .navigationBarItems( trailing:
                                                                    HStack {
                            Button ( action:  { }, label: { Image(systemName: "play").foregroundColor(.white)})
                            Button ( action:  { }, label: { Image(systemName: "pencil.tip.crop.circle").foregroundColor(.white)})
                            Button ( action:  { }, label: { Image(systemName: "person").foregroundColor(.white)})
                        }
                        )
                    Image("DemoScene")
                        .resizable()
                        .ignoresSafeArea()
                        .scaledToFill()
                        .toolbar { // <2>
                            ToolbarItem(placement: .principal) {
                                TextField("website url", text: $website)
                                    .textFieldStyle(.roundedBorder)
                                    .textInputAutocapitalization(.never)
                                    .disableAutocorrection(true)
                            }
                        }
                }
                    .tabItem {
                        Image(systemName: "map")
                        Text("Web")
                    }
                    .tag(1)
                Text("Second View")
                    .padding()
                    .tabItem {
                        Image(systemName: "rectangle.grid.2x2")
                        Text("Gallery")
                    }
                    .tag(2)
            }
            .accentColor(.white)
        }
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
