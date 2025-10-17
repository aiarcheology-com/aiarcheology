//
//  ImportHandler.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 17.10.25.
//

import Foundation

struct ImportHandler: Equatable {
    let call: @MainActor (URL, UUID, ModelProvider) -> Void
    static func == (lhs: ImportHandler, rhs: ImportHandler) -> Bool { true } // treat as stable
}
