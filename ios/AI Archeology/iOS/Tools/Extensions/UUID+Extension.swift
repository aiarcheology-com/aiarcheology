//
//  UUID+Extension.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 28.10.25.
//
import Foundation


extension UUID {
    static func zeros() -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}
