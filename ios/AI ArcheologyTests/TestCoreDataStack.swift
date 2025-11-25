//
//  TestCoreDataStack.swift
//  AI ArcheologyTests
//
//  Created by AI Assistant on 20.11.25.
//

import CoreData
@testable import ML_Browser

final class TestCoreDataStack {
    let container: NSPersistentContainer
    
    init() {
        container = NSPersistentContainer(name: "MLBrowser")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        
        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Failed to load in-memory store: \(error)")
            }
        }
    }
    
    var viewContext: NSManagedObjectContext {
        container.viewContext
    }
}
