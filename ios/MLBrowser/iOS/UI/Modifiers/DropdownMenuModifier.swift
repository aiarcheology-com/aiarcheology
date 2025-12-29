//
//  DropdownMenuModifier.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

import SwiftUI

	// Please, Apple, make a real native dropdown menu for textField
struct DropdownMenuModifier<Item, ItemContent: View, CancelContent: View>: ViewModifier where Item: Hashable {
	var backgroundColor: Color = .clear
	var items: [Item]
	var cancelContent: () -> CancelContent
	var itemContent: (Item) -> ItemContent

	func body(content baseContent: Content) -> some View {
		if items.isEmpty {
			baseContent
		} else {
			GeometryReader { geometry in
				let dropdownWidth: CGFloat = 0.6 * geometry.size.width
				let dropdownHeight: CGFloat = 0.4 * geometry.size.height
				let strokeColor: Color = Color.gray.opacity(0.5)
				let shadowColor: Color = Color.black.opacity(0.75)

				ZStack(alignment: .top) {
					baseContent
					VStack {
						Spacer()
							.frame(height: 42)
							.allowsHitTesting(false)
						ScrollView {
							cancelContent()
							VStack(alignment: .leading) {
								ForEach(Array(items.enumerated()), id: \.offset) { index, item in
									itemContent(item)
										.padding(5)
										.transition(.opacity)
								}
							}
							.background(backgroundColor)
						}
						.frame(width: dropdownWidth, height: dropdownHeight)
						.padding(5)
						.background(
							RoundedRectangle(cornerRadius: 5)
								.fill(backgroundColor)
								.overlay(
									RoundedRectangle(cornerRadius: 5)
										.stroke(strokeColor, lineWidth: 0.5)
								)
								.shadow(color: shadowColor, radius: 5, x: 0, y: 0)
						)
					}
					.animation(.easeInOut, value: items)
				}
			}
		}
	}
}

extension View {
	public func dropDownMenu<Item, CancelContent: View, ItemContent: View>(
		items: [Item],
		backgroundColor: Color,
		@ViewBuilder cancelContent: @escaping () -> CancelContent,
		@ViewBuilder itemContent: @escaping (Item) -> ItemContent)
	-> some View where Item: Hashable {

		modifier(DropdownMenuModifier(backgroundColor: backgroundColor,
									  items: items,
									  cancelContent: cancelContent,
									  itemContent: itemContent)
		)
	}
}
