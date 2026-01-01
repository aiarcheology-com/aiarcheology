//
//  CoreDataManagable.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 14.12.23.
//

@preconcurrency import CoreData
import OSLog

enum CoreDataManageableState: String, RawRepresentable {
    case undefined
    case empty
    case draft
    case ready
    case deprecated
    
    func callAsFunction() -> RawValue { rawValue }
}

struct CoreDataManagableValidationIssue: Identifiable, Hashable {
    let id = UUID()
    let key: String
    let message: String
}

struct CoreDataManagableValidationReport: Hashable {
    static let zeroIssues: [CoreDataManagableValidationIssue] = []
    var issues: [CoreDataManagableValidationIssue]?
    var isValid: Bool { issues?.isEmpty ?? true }
}

protocol CoreDataManagableWithState: CoreDataManageable where Self: NSManagedObject {
    var lifeCycleString: String { get set }
    var lifeCycle: CoreDataManageableState { get set }
    func validationReport() -> CoreDataManagableValidationReport
}

extension CoreDataManagableWithState {
    var lifeCycle: CoreDataManageableState {
        get {
            .init(rawValue: lifeCycleString) ?? CoreDataManageableState.undefined
        }
        set {
            lifeCycleString = newValue.rawValue
        }
    }
    
    /// Default state mapping (can be overridden per type by shadowing these helpers).
    fileprivate var allowedTransitions: [CoreDataManageableState: Set<CoreDataManageableState>] {
        [
            .undefined: [.empty, .draft],
            .empty: [.draft, .deprecated],
            .draft: [.ready, .empty, .deprecated],
            .ready: [.deprecated],
            .deprecated: [.empty] // allow resurrection if needed
        ]
    }
        
    /// Default: never auto-archive unless type opts in.
    func shouldDeprecate() -> Bool { false }
        
    /// Pure decision function that *suggests* where to go next from the current state.
    /// You can override this per entity to customize behavior.
    func suggestedNextState() -> CoreDataManageableState {
        switch lifeCycle {
        case .undefined, .empty:
            return hasChanges ? .draft : .empty
        case .draft:
            let valid = validationReport().isValid
            return valid ? .ready : (hasChanges ? .draft : .empty)
        case .ready:
            return shouldDeprecate() ? .deprecated : .ready
        case .deprecated:
            return hasChanges ? .draft : .deprecated
        }
    }
    
    /// Move to the next suggested state if allowed. Does not save; call `persist()` to save.
    @discardableResult
    func move() -> CoreDataManageableState {
        let nextState = suggestedNextState()
        return transition(to: nextState)
    }
    
    /// Checks the transition graph.
    func canTransition(to newState: CoreDataManageableState) -> Bool {
        allowedTransitions[lifeCycle]?.contains(newState) ?? false
    }
    
    /// Performs a transition if allowed. Does not save; call `persist()` to save.
    @discardableResult
    func transition(to newState: CoreDataManageableState) -> CoreDataManageableState {
        guard canTransition(to: newState) else { return lifeCycle }
        lifeCycle = newState
        return lifeCycle
    }
    
    /// Explicit domain helpers for common events:
    @discardableResult
    func markDeprecated() -> CoreDataManageableState { transition(to: .deprecated) }
    
    /// Resets attributes to default values (to be overridden per type).
    func resetAttributesToDefaults() {}
    
    /// Resets object in the context
    @discardableResult
    func reset() -> CoreDataManageableState {
        if let context = self.managedObjectContext {
            if isInserted {
                // For new objects: just reset properties manually
                resetAttributesToDefaults()
                return transition(to: .empty)
            } else {
                // For existing objects: reload from store
                context.refresh(self, mergeChanges: false)
                return lifeCycle
            }
        }
        return lifeCycle
    }

    /// Persist helper (since we’re on NSManagedObject we have a context handy).
    func persist(in context: NSManagedObjectContext) { Self.save(in: context) }
    
    /// Validation throwing helper for Core Data hooks.
    func throwIfInvalid() throws {
        let report = validationReport()
        guard !report.isValid else { return }
        
        // Build one NSError per issue
        guard let issues = report.issues else { return }
        let detailedErrors: [NSError] = issues.map { issue in
            NSError(
                domain: "DeepConfiguration",
                code: 1000,
                userInfo: [
                    NSLocalizedDescriptionKey: "Validation error – \(issue.key): \(issue.message)",
                    NSValidationKeyErrorKey: issue.key
                ]
            )
        }
        
        // Wrap them in a single container error per Cocoa conventions
        let container = NSError(
            domain: "DeepConfiguration",
            code: 1001,
            userInfo: [
                NSLocalizedDescriptionKey: "Validation failed with \(detailedErrors.count) issue(s).",
                NSDetailedErrorsKey: detailedErrors
            ]
        )
        
        throw container
    }
}

protocol CoreDataManageable where Self: NSManagedObject {
    var entityId: UUID { get }
    static func create(in context: NSManagedObjectContext) -> Self
    static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: @escaping @Sendable (Self) -> Void)
    static func deleteAll(in context: NSManagedObjectContext, executeAndMerge: Bool)
    static func delete(_ entityId: UUID, in context: NSManagedObjectContext)
    static func delete(_ entity: Self, in context: NSManagedObjectContext)
    static func select(_ entityId: UUID, in context: NSManagedObjectContext) -> Self?
    static func selectAll(in context: NSManagedObjectContext) -> [Self]
    static func count(in context: NSManagedObjectContext, predicate: NSPredicate?) -> Int
    static func save(in context: NSManagedObjectContext)
}

extension CoreDataManageable where Self: NSManagedObject {
    /// Creates a new entity in the specified context.
    ///
    /// This method wraps the creation in `performAndWait` to ensure thread safety.
    /// Note: If called from code already on the context's queue (e.g., within another
    /// `performAndWait` block), this will result in nested `performAndWait` calls,
    /// which is safe but slightly less efficient.
    ///
    /// - Parameter context: The `NSManagedObjectContext` in which to create the entity.
    /// - Returns: The newly created entity.
    static func create(in context: NSManagedObjectContext) -> Self {
        // nonisolated(unsafe) is safe here because performAndWait executes synchronously
        // on the calling thread, blocking until completion. The entity reference won't
        // escape until after the closure completes.
        // swiftlint:disable:next implicitly_unwrapped_optional
        nonisolated(unsafe) var entity: Self!
        context.performAndWait {
            LoggingPolicy.debug("Creating new \(String(describing: Self.self)) entity", logger: .storage)
            entity = Self(context: context)
        }
        return entity
    }
    
    /// Updates an entity identified by its UUID.
    ///
    /// This method performs the update and immediately saves the context.
    /// **Behavior change**: Unlike the previous implementation, this now saves
    /// automatically inside the `performAndWait` block, preventing forgotten saves
    /// but removing the ability to batch multiple updates before saving.
    ///
    /// For batching multiple updates before saving, use `batchedUpdate(_:in:with:)` instead,
    /// which allows you to perform multiple updates and then call `save(in:)` once.
    ///
    /// - Parameters:
    ///   - entityId: The identifier of the entity to update.
    ///   - context: The `NSManagedObjectContext` in which the update occurs.
    ///   - updateClosure: A closure that mutates the fetched entity.
    static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: @escaping @Sendable (Self) -> Void) {
        context.performAndWait {
            let request = Self.fetchRequest()
            request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

            do {
                let objects = try context.fetch(request) as? [Self]
                guard let count = objects?.count else {
                    LoggingPolicy.error("Failed to fetch objects for update - unexpected nil result for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)", logger: .storage)
                    return
                }

                if count != 1 {
                    LoggingPolicy.warning("Expected 1 instance for update but found \(count) for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)", logger: .storage)
                }

                guard let objectToUpdate = objects?.first else {
                    LoggingPolicy.warning("No object found to update for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)", logger: .storage)
                    return
                }

                updateClosure(objectToUpdate)

                // Save inside the same performAndWait to avoid nested calls
                if context.hasChanges {
                    try context.save()
                    LoggingPolicy.debug("Successfully updated \(String(describing: Self.self)) entity with ID \(entityId.uuidString)", logger: .storage)
                }
            } catch {
                LoggingPolicy.error("Update error for \(String(describing: Self.self)): \(error.localizedDescription)", logger: .storage)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "update", "entityType": String(describing: Self.self)])
            }
        }
    }
    
    /// Performs an update on the entity without saving the context.
    ///
    /// Use this when you want to batch multiple updates and persist them
    /// together by calling `save(in:)` on the same context afterward.
    ///
    /// Example:
    /// ```swift
    /// // Batch multiple updates before saving
    /// Entity.batchedUpdate(id1, in: context) { entity in
    ///     entity.property = newValue1
    /// }
    /// Entity.batchedUpdate(id2, in: context) { entity in
    ///     entity.property = newValue2
    /// }
    /// Entity.save(in: context) // Save all changes at once
    /// ```
    ///
    /// - Parameters:
    ///   - entityId: The identifier of the entity to update.
    ///   - context: The `NSManagedObjectContext` in which the update occurs.
    ///   - updateClosure: A closure that mutates the fetched entity.
    static func batchedUpdate(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: @escaping @Sendable (Self) -> Void) {
        context.performAndWait {
            let request = Self.fetchRequest()
            request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

            do {
                let objects = try context.fetch(request) as? [Self]
                guard let count = objects?.count else {
                    LoggingPolicy.error("Failed to fetch objects for batched update - unexpected nil result for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)", logger: .storage)
                    return
                }

                if count != 1 {
                    LoggingPolicy.warning("Expected 1 instance for batched update but found \(count) for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)", logger: .storage)
                }

                guard let objectToUpdate = objects?.first else {
                    LoggingPolicy.warning("No object found to update for batched update for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)", logger: .storage)
                    return
                }

                updateClosure(objectToUpdate)
                LoggingPolicy.debug("Successfully applied batched update to \(String(describing: Self.self)) entity with ID \(entityId.uuidString) (not yet saved)", logger: .storage)
            } catch {
                LoggingPolicy.error("Batched update error for \(String(describing: Self.self)): \(error.localizedDescription)", logger: .storage)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "batchedUpdate", "entityType": String(describing: Self.self)])
            }
        }
    }
    
    static func save(in context: NSManagedObjectContext) {
        context.performAndWait {
            do {
                if context.hasChanges {
                    try context.save()
                    LoggingPolicy.debug("Successfully saved context changes for \(String(describing: Self.self))", logger: .storage)
                }
            } catch {
                LoggingPolicy.error("CoreData save error for \(String(describing: Self.self)): \(error.localizedDescription)", logger: .storage)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "save", "entityType": String(describing: Self.self)])
            }
        }
    }
    
    static func delete(_ entity: Self, in context: NSManagedObjectContext) {
        let objectID = entity.objectID
        context.performAndWait {
            do {
                let entityToDelete = try context.existingObject(with: objectID)
                LoggingPolicy.debug("Deleting \(String(describing: Self.self)) entity", logger: .storage)
                context.delete(entityToDelete)
                try context.save()
                LoggingPolicy.info("Successfully deleted \(String(describing: Self.self)) entity", logger: .storage)
            } catch {
                LoggingPolicy.error("Error deleting \(String(describing: Self.self)): \(error.localizedDescription)", logger: .storage)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "delete", "entityType": String(describing: Self.self)])
            }
        }
    }
    
    static func deleteAll(in context: NSManagedObjectContext, executeAndMerge: Bool = false) {
        context.performAndWait {
            let fetchRequest: NSFetchRequest<NSFetchRequestResult> = Self.fetchRequest()
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            do {
                if executeAndMerge.enabled {
                    // NSBatchDeleteRequest operates directly on the persistent store and persists changes immediately.
                    // executeAndMerge merges the deleted object IDs into this context so it reflects the deletions.
                    // No context.save() is needed - the store is already updated.
                    // Other contexts will only see deletions if they refresh or have automaticallyMergesChangesFromParent enabled.
                    try context.executeAndMergeChanges(using: deleteRequest)
                } else {
                    // NSBatchDeleteRequest operates directly on the persistent store and persists changes immediately.
                    // This context will NOT be updated to reflect the deletions (it retains stale references).
                    // No context.save() is needed - the store is already updated.
                    // Other contexts will only see deletions if they refresh or have automaticallyMergesChangesFromParent enabled.
                    try context.execute(deleteRequest)
                }
                LoggingPolicy.info("Successfully deleted all \(String(describing: Self.self)) entities", logger: .storage)
            } catch {
                LoggingPolicy.error("Error deleting all entities \(String(describing: Self.self)): \(error.localizedDescription)", logger: .storage)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "deleteAll", "entityType": String(describing: Self.self)])
            }
        }
    }
    
    static func delete(_ entityId: UUID, in context: NSManagedObjectContext) {
        context.performAndWait {
            let request = Self.fetchRequest()
            request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

            do {
                let objects = try context.fetch(request) as? [Self]
                guard let objectToDelete = objects?.first else {
                    LoggingPolicy.debug("No object found to delete for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)", logger: .storage)
                    return
                }

                context.delete(objectToDelete)
                try context.save()
                LoggingPolicy.debug("Successfully deleted \(String(describing: Self.self)) entity with ID \(entityId.uuidString)", logger: .storage)
            } catch {
                LoggingPolicy.error("Deletion error for \(String(describing: Self.self)): \(error.localizedDescription)", logger: .storage)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "delete", "entityType": String(describing: Self.self)])
            }
        }
    }
    
    static func select(_ entityId: UUID, in context: NSManagedObjectContext) -> Self? {
        // nonisolated(unsafe) is safe here because performAndWait executes synchronously,
        // blocking until the closure completes. The result won't be accessed until after
        // the performAndWait block finishes.
        nonisolated(unsafe) var result: Self?
        context.performAndWait {
            let request = Self.fetchRequest()
            request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)

            do {
                let objects = try context.fetch(request) as? [Self]
                let count = objects?.count ?? 0

                if count > 1 {
                    LoggingPolicy.warning("Expected at most 1 instance but found \(count) for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)", logger: .storage)
                }

                result = objects?.first
            } catch {
                LoggingPolicy.error("Error fetching object \(String(describing: Self.self)): \(error.localizedDescription)", logger: .storage)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "select", "entityType": String(describing: Self.self)])
            }
        }
        return result
    }
    
    /// Selects all entities of this type from the context.
    ///
    /// This is a convenience method that calls the enhanced `selectAll` with default parameters.
    ///
    /// - Parameter context: The `NSManagedObjectContext` to fetch from.
    /// - Returns: An array of all entities.
    static func selectAll(in context: NSManagedObjectContext) -> [Self] {
        selectAll(in: context, fetchLimit: nil, fetchBatchSize: 20)
    }

    /// Selects all entities with fetch optimizations.
    ///
    /// - Parameters:
    ///   - context: The `NSManagedObjectContext` to fetch from.
    ///   - fetchLimit: Maximum number of results to return. When `nil`, all entities are returned.
    ///                 Use this for pagination or when you only need a subset of results.
    ///   - fetchBatchSize: Number of objects to fault into memory at once (default: 20).
    ///                     This controls memory usage during iteration. Higher values improve
    ///                     performance for large result sets but use more memory.
    /// - Returns: An array of entities, limited by `fetchLimit` if specified.
    static func selectAll(
        in context: NSManagedObjectContext,
        fetchLimit: Int?,
        fetchBatchSize: Int = 20
    ) -> [Self] {
        // nonisolated(unsafe) is safe here because performAndWait is synchronous and blocks
        // until completion. The result array won't be accessed until after the closure finishes.
        nonisolated(unsafe) var result: [Self] = []
        context.performAndWait {
            let request = Self.fetchRequest()
            if let limit = fetchLimit {
                request.fetchLimit = limit
            }
            request.fetchBatchSize = fetchBatchSize

            do {
                let objects = try context.fetch(request) as? [Self]
                LoggingPolicy.debug("Fetched \((objects?.count ?? 0)) \(String(describing: Self.self)) entities", logger: .storage)
                result = objects ?? []
            } catch {
                LoggingPolicy.error("Error fetching all objects \(String(describing: Self.self)): \(error.localizedDescription)", logger: .storage)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "getAll", "entityType": String(describing: Self.self)])
            }
        }
        return result
    }

    /// Efficiently counts entities without fetching them into memory.
    ///
    /// Use this instead of `selectAll(in:).count` for better performance, especially
    /// with large datasets. This method executes a lightweight count query that doesn't
    /// load objects into memory.
    ///
    /// - Parameters:
    ///   - context: The `NSManagedObjectContext` to count in.
    ///   - predicate: Optional predicate to filter the count. When `nil`, counts all entities.
    /// - Returns: The number of entities matching the predicate (or all entities if predicate is nil).
    static func count(in context: NSManagedObjectContext, predicate: NSPredicate? = nil) -> Int {
        // nonisolated(unsafe) is safe here because performAndWait is synchronous and blocks
        // until completion. Both the result and predicateRef won't be accessed/escape until
        // after the performAndWait block completes.
        nonisolated(unsafe) var result = 0
        nonisolated(unsafe) let predicateRef = predicate
        context.performAndWait {
            let request = Self.fetchRequest()
            request.predicate = predicateRef
            do {
                result = try context.count(for: request)
                LoggingPolicy.debug("Count for \(String(describing: Self.self)): \(result)", logger: .storage)
            } catch {
                LoggingPolicy.error("Error counting \(String(describing: Self.self)): \(error.localizedDescription)", logger: .storage)
                DefaultCrashReporter.shared.recordError(error, context: ["operation": "count", "entityType": String(describing: Self.self)])
            }
        }
        return result
    }
}
