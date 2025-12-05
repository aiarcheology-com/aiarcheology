//
//  SnapAdjustmentOverlay.swift
//  AI Archeology
//
//  Created by Vladimír Slavík.
//

import SwiftUI

/// A transparent full-screen overlay that presents the SnapAdjustmentView
/// in the bottom trailing corner on iPhone.
///
/// This allows the user to see the content they're adjusting while
/// manipulating brightness, contrast, and saturation controls.
struct SnapAdjustmentOverlay: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var snapAdjustment: SnapAdjustment
    
    /// Padding from screen edges
    private let edgePadding: CGFloat = 16
    
    var body: some View {
        // Position panel at bottom trailing without blocking touches elsewhere
        VStack {
            Spacer()
            HStack {
                Spacer()
                adjustmentPanel
            }
        }
        .padding(edgePadding)
        .padding(.bottom, 8)
        .ignoresSafeArea(.keyboard)
    }
    
    // MARK: - Adjustment Panel
    
    private var adjustmentPanel: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                Text("Adjustments")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .testability(Testability.Button.snapAdjustmentOverlayDismiss)
            }
            .padding(.bottom, 12)
            
            // Controls
            SnapAdjustmentView()
                .environmentObject(snapAdjustment)
        }
        .padding(16)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
    }
}

// MARK: - View Extension for Easy Usage

extension View {
    /// Presents the snap adjustment overlay on iPhone.
    /// 
    /// - Parameters:
    ///   - isPresented: Binding to control visibility
    ///   - snapAdjustment: The SnapAdjustment environment object
    func snapAdjustmentOverlay(
        isPresented: Binding<Bool>,
        snapAdjustment: SnapAdjustment
    ) -> some View {
        self.overlay {
            if isPresented.wrappedValue {
                SnapAdjustmentOverlay(isPresented: isPresented)
                    .environmentObject(snapAdjustment)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewContainer: View {
        @State private var isPresented = true
        @StateObject private var snapAdjustment = SnapAdjustment()
        
        var body: some View {
            ZStack {
                // Simulated content
                LinearGradient(
                    colors: [.blue, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack {
                    Text("Content Preview")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                    Text("Tap outside panel to dismiss")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .snapAdjustmentOverlay(
                isPresented: $isPresented,
                snapAdjustment: snapAdjustment
            )
        }
    }
    
    return PreviewContainer()
}
