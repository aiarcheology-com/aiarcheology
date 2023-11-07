//
//  Sequence+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 07.11.23.
//

import Foundation

// https://www.swiftbysundell.com/articles/async-and-concurrent-forEach-and-map/
extension Sequence {
	func concurrentForEach(
		_ operation: @escaping (Element) async -> Void
	) async {
		await withTaskGroup(of: Void.self) { group in
			for element in self {
				group.addTask {
					await operation(element)
				}
			}
		}
	}
}
