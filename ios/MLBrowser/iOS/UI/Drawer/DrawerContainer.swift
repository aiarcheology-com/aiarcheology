//
//  DrawerContainer.swift
//  AI Archeology
//
//  Created by Vladimír Slavík.
//

import SwiftUI

/// A generic container that provides a left-aligned drawer overlay.
///
/// The drawer slides in from the leading edge and partially covers the main content.
/// It follows modern iOS patterns with proper accessibility support.
///
/// Usage:
/// ```swift
/// DrawerContainer(manager: drawerManager) {
///     MainContentView()
/// } menu: {
///     MenuContentView()
/// }
/// ```
struct DrawerContainer<Content: View, Menu: View>: View {
    @Bindable var manager: DrawerManager
    @ViewBuilder var content: Content
    @ViewBuilder var menu: Menu
    
    /// Width of the drawer when fully open
    private let drawerWidth: CGFloat = 300
    
    /// Threshold for swipe-to-close gesture (in points)
    private let closeThreshold: CGFloat = 50
    
    var body: some View {
        ZStack(alignment: .leading) {
            mainContentLayer
            
            if manager.isOpen {
                scrimLayer
                drawerLayer
            }
        }
    }
    
    // MARK: - Layers
    
    /// The main content sits at the base of the ZStack
    private var mainContentLayer: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Accessibility: Hide content from VoiceOver when drawer is open
            .accessibilityHidden(manager.isOpen)
            // Interaction: Prevent taps from reaching content when drawer is open
            .disabled(manager.isOpen)
    }
    
    /// Semi-transparent overlay that dims the main content and handles tap-to-close
    private var scrimLayer: some View {
        Color.black
            .opacity(0.3)
            .ignoresSafeArea()
            .onTapGesture {
                manager.close()
            }
            .transition(.opacity)
            .zIndex(1)
    }
    
    /// The drawer view that slides in from the leading edge
    private var drawerLayer: some View {
        menu
            .frame(width: drawerWidth)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .ignoresSafeArea()
            .transition(.move(edge: .leading))
            .zIndex(2)
            // Accessibility: Mark drawer as modal context
            .accessibilityAddTraits(.isModal)
            // Gesture: Swipe left to close
            .gesture(swipeToCloseGesture)
    }
    
    // MARK: - Gestures
    
    /// Drag gesture that closes the drawer when swiping left
    private var swipeToCloseGesture: some Gesture {
        DragGesture()
            .onEnded { value in
                // Close if dragged left past threshold OR if velocity indicates intent
                let horizontalTranslation = value.translation.width
                let predictedEnd = value.predictedEndTranslation.width
                
                if horizontalTranslation < -closeThreshold || predictedEnd < -closeThreshold {
                    manager.close()
                }
            }
    }
}

#if DEBUG
// MARK: - Preview

#Preview("Drawer Closed") {
    @Previewable @State var manager = DrawerManager()
    
    DrawerContainer(manager: manager) {
        Color.blue.opacity(0.3)
            .overlay {
                VStack {
                    Text("Main Content")
                    Button("Open Drawer") {
                        manager.open()
                    }
                }
            }
    } menu: {
        VStack(alignment: .leading) {
            Text("Menu")
                .font(.largeTitle)
                .bold()
                .padding(.top, 60)
            
            Button("Item 1") {}
            Button("Item 2") {}
            Button("Item 3") {}
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Drawer Open") {
    @Previewable @State var manager: DrawerManager = {
        let m = DrawerManager()
        m.isOpen = true
        return m
    }()
    
    DrawerContainer(manager: manager) {
        Color.blue.opacity(0.3)
            .overlay {
                Text("Main Content")
            }
    } menu: {
        VStack(alignment: .leading) {
            Text("Menu")
                .font(.largeTitle)
                .bold()
                .padding(.top, 60)
            
            Button("Item 1") {}
            Button("Item 2") {}
            Button("Item 3") {}
            
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
