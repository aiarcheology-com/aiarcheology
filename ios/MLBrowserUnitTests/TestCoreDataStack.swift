//
//  TestCoreDataStack.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 20.11.25.
//

import CoreData
@testable import ML_Browser

/// Test helper that wraps DataController to provide a consistent Core Data stack.
/// Uses DataController internally to ensure the shared managed object model is used,
/// avoiding duplicate entity description issues when running multiple tests.
final class TestCoreDataStack {
    let container: NSPersistentContainer

    nonisolated init() {
        // Tests always run on the main thread, so we can safely assume main actor isolation
        container = MainActor.assumeIsolated {
            let dataController = DataController(inMemory: true)
            return dataController.container
        }
    }

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }
}
