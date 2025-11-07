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
    var isValid: Bool { issues.map { $0.isEmpty } ?? false }
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
            .undefined:    [.empty, .draft],
            .empty:        [.draft, .deprecated],
            .draft:        [.ready, .empty, .deprecated],
            .ready:        [.deprecated],
            .deprecated:   [.empty] // allow resurrection if needed
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
    static func save(in context: NSManagedObjectContext)
}

extension CoreDataManageable where Self: NSManagedObject {
    static func create(in context: NSManagedObjectContext) -> Self {
        Logger.persistence.logDebug("Creating new \(String(describing: Self.self)) entity")
        return Self(context: context)
    }
    
    static func update(_ entityId: UUID, in context: NSManagedObjectContext, with updateClosure: @escaping @Sendable (Self) -> Void) {
        let request = Self.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)
        
        do {
            let objects = try context.fetch(request) as? [Self]
            guard let count = objects?.count else {
                Logger.persistence.logError("Failed to fetch objects for update - unexpected nil result for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)")
                return
            }
            
            if count != 1 {
                Logger.persistence.logWarning("Expected 1 instance for update but found \(count) for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)")
            }
            
            guard let objectToUpdate = objects?.first else {
                Logger.persistence.logWarning("No object found to update for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)")
                return
            }
            
            updateClosure(objectToUpdate)
            
            
            save(in: context)
            
            Logger.persistence.logDebug("Successfully updated \(String(describing: Self.self)) entity with ID \(entityId.uuidString)")
        } catch {
            Logger.persistence.logError("Update error for \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "update", "entityType": String(describing: Self.self)])
        }
    }
    
    static func save(in context: NSManagedObjectContext) {
        do {
            if context.hasChanges {
                try context.save()
                Logger.persistence.logDebug("Successfully saved context changes for \(String(describing: Self.self))")
            }
        } catch {
            Logger.persistence.logError("CoreData save error for \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "save", "entityType": String(describing: Self.self)])
        }
    }
    
    static func delete(_ entity: Self, in context: NSManagedObjectContext) {
        let objectID = entity.objectID
        do {
            let entityToDelete = try context.existingObject(with: objectID)
            Logger.persistence.logDebug("Deleting \(String(describing: Self.self)) entity")
            context.delete(entityToDelete)
            save(in: context)
            Logger.persistence.logInfo("Successfully deleted \(String(describing: Self.self)) entity")
        } catch {
            Logger.persistence.logError("Error fetching object for deletion \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "delete", "entityType": String(describing: Self.self)])
        }
    }
    
    static func deleteAll(in context: NSManagedObjectContext, executeAndMerge: Bool = false) {
        let fetchRequest: NSFetchRequest<NSFetchRequestResult> = Self.fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        do {
            if executeAndMerge.enabled {
                try context.executeAndMergeChanges(using: deleteRequest)
            } else {
                try context.execute(deleteRequest)
            }
            
            save(in: context)
            Logger.persistence.logInfo("Successfully deleted all \(String(describing: Self.self)) entities")
        } catch {
            Logger.persistence.logError("Error deleting all entities \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "deleteAll", "entityType": String(describing: Self.self)])
        }
    }
    
    static func delete(_ entityId: UUID, in context: NSManagedObjectContext) {
        let request = Self.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)
        
        do {
            let objects = try context.fetch(request) as? [Self]
            guard let objectToDelete = objects?.first else {
                Logger.persistence.logDebug("No object found to delete for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)")
                return
            }
            
            context.delete(objectToDelete)
            save(in: context)
            Logger.persistence.logDebug("Successfully deleted \(String(describing: Self.self)) entity with ID \(entityId.uuidString)")
        } catch {
            Logger.persistence.logError("Deletion error for \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "delete", "entityType": String(describing: Self.self)])
        }
    }
    
    static func select(_ entityId: UUID, in context: NSManagedObjectContext) -> Self? {
        let request = Self.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", "entityId", entityId as CVarArg)
        
        nonisolated(unsafe) var result: Self?
        do {
            let objects = try context.fetch(request) as? [Self]
            let count = objects?.count ?? 0
            
            if count > 1 {
                Logger.persistence.logWarning("Expected at most 1 instance but found \(count) for entity \(String(describing: Self.self)) with ID \(entityId.uuidString)")
            }
            
            result = objects?.first //Capture of 'result' with non-Sendable type 'Self?' in a '@Sendable' closure
        } catch {
            Logger.persistence.logError("Error fetching object \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "select", "entityType": String(describing: Self.self)])
        }
        return result
    }
    
    static func selectAll(in context: NSManagedObjectContext) -> [Self] {
        let request = Self.fetchRequest()
        
        nonisolated(unsafe) var result: [Self] = []
        do {
            let objects = try context.fetch(request) as? [Self]
            Logger.persistence.logDebug("Fetched \((objects?.count ?? 0)) \(String(describing: Self.self)) entities")
            result = objects ?? []
        } catch {
            Logger.persistence.logError("Error fetching all objects \(String(describing: Self.self)): \(error.localizedDescription)")
            DefaultCrashReporter.shared.recordError(error, context: ["operation": "getAll", "entityType": String(describing: Self.self)])
        }
        return result
    }
}
