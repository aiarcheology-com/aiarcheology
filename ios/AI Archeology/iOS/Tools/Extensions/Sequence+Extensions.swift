//
//  Sequence+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 07.11.23.
//

import Foundation

// https://www.swiftbysundell.com/articles/async-and-concurrent-forEach-and-map/
extension Sequence where Element: Sendable {
    func concurrentForEach(
        _ operation: @escaping @Sendable (Element) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for element in self {
                let value = element
                group.addTask {
                    await operation(value)
                }
            }
        }
    }
}
