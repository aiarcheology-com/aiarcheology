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
@MainActor
final class TestCoreDataStack {
    private let dataController: DataController

    var container: NSPersistentContainer {
        dataController.container
    }

    init() {
        dataController = DataController(inMemory: true)
    }

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }
}
