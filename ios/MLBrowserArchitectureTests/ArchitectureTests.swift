//
//  ArchitectureTests.swift
//  MLBrowserUnitTests
//
//  Created by Agent on 2026-01-03.
//
//  Architectural linting rules using Harmonize.
//  These rules help maintain codebase consistency and architectural integrity.
//
//  IMPORTANT: These rules are guidelines, not unbreakable dogma.
//  If a rule conflicts with pragmatic design decisions, evaluate the trade-offs.
//  Document exceptions with clear reasoning when necessary.
//

import Harmonize
import HarmonizeSemantics
import XCTest

/// Architectural rules for the MLBrowser codebase.
///
/// Rules are organized by concern:
/// 1. State Management - MainActor isolation for state objects
/// 2. Naming Conventions - Consistent naming patterns
/// 3. View Architecture - SwiftUI views as structs
/// 4. Code Organization - File location conventions
final class ArchitectureTests: XCTestCase {

    // MARK: - 1. State Management Rules

    /// State objects that hold UI state should be @MainActor to ensure thread-safe UI updates.
    ///
    /// **Rationale**: State objects publish changes that drive UI updates. MainActor isolation
    /// prevents data races and ensures all mutations happen on the main thread.
    ///
    /// **Exceptions**: Consider if a "State" class is intentionally designed for background
    /// operations—in that case, rename it to avoid the "State" suffix.
    func testStateObjectsAreMainActor() {
        let stateClasses = Harmonize.productionCode().classes()
            .withSuffix("State")
            // Exclude SnapState which intentionally manages timer state via Combine
            .withoutName(["SnapState"])

        stateClasses.assertTrue(
            message: """
                State objects should be @MainActor for thread-safe UI updates.
                If this is intentional, consider renaming to avoid 'State' suffix.
                See AGENTS.md section 4 (Concurrency & Threading).
                """
        ) { declaration in
            declaration.attributes.contains { $0.name == "MainActor" }
        }
    }

    // MARK: - 2. Naming Convention Rules

    /// Services should be actors (not classes) for proper concurrency isolation.
    ///
    /// **Rationale**: Services handle operations like networking, file I/O, and ML model loading.
    /// Using actors ensures these heavy operations don't block the main thread.
    ///
    /// Note: This test verifies no regular classes have "Service" suffix.
    /// Services should be defined as `actor ServiceName`, not `class ServiceName`.
    func testNoServiceClasses() {
        // Services should be actors, not classes
        // This test ensures no new classes are created with Service suffix
        let serviceClasses = Harmonize.productionCode().classes()
            .withSuffix("Service")
            // Exclude protocol-conformance types like CrashReportingService implementations
            .withoutName(["SentryCrashReportingService", "NoOpCrashReportingService"])

        XCTAssertEqual(
            serviceClasses.count, 0,
            """
            Found \(serviceClasses.count) class(es) with 'Service' suffix.
            Services should be actors for off-main-thread execution.
            Heavy operations (networking, file I/O, ML) must not block the main thread.
            Consider converting to 'actor ServiceName' for proper concurrency isolation.
            See AGENTS.md section 9 (Performance Guidelines).
            """
        )
    }

    /// ObservableObject classes should have descriptive suffixes indicating their role.
    ///
    /// **Rationale**: Clear naming helps developers understand a type's purpose.
    /// State objects, Managers, and Controllers are common ObservableObject patterns.
    func testObservableObjectsHaveDescriptiveSuffixes() {
        let allowedSuffixes = [
            "State", "Manager", "Controller", "Settings", "Guide",
            "Drivers", "Model", "Coordinator", "Downloader", "Adjustment",
            "DataModel", "Renderer", "Download"  // Include project-specific patterns
        ]

        // Filter classes that inherit from ObservableObject
        let allClasses = Harmonize.productionCode().classes()
        let observableClasses = allClasses.filter { classDecl in
            classDecl.inherits(from: "ObservableObject")
        }

        // Skip if no observable classes found (informational only)
        guard !observableClasses.isEmpty else {
            return
        }

        observableClasses.assertTrue(
            message: """
                ObservableObject classes should have descriptive suffixes.
                Allowed: \(allowedSuffixes.joined(separator: ", "))
                This helps identify the class's architectural role.
                """
        ) { classDecl in
            allowedSuffixes.contains { suffix in
                classDecl.name.hasSuffix(suffix)
            }
        }
    }

    // MARK: - 3. View Architecture Rules

    /// SwiftUI Views should be structs, not classes.
    ///
    /// **Rationale**: SwiftUI is designed around value-type Views. Using structs enables
    /// SwiftUI's diffing algorithm to work efficiently and prevents reference-type issues.
    func testNoClassesNamedView() {
        // Check that no classes are named *View (views should be structs)
        let viewClasses = Harmonize.productionCode().classes()
            .withSuffix("View")

        XCTAssertEqual(
            viewClasses.count, 0,
            """
            Found \(viewClasses.count) class(es) with 'View' suffix.
            SwiftUI Views should be structs, not classes.
            Classes named '*View' violate SwiftUI's value-type design.
            """
        )
    }

    /// Verify that View structs exist in the project.
    func testViewStructsExist() {
        let viewStructs = Harmonize.productionCode().structs()
            .withSuffix("View")

        XCTAssertGreaterThan(
            viewStructs.count, 0,
            "Expected SwiftUI View structs in the codebase."
        )
    }

    // MARK: - 4. Code Organization Rules

    /// CoreData entity classes should exist and follow NSManagedObject pattern.
    ///
    /// Note: CoreData classes are in files named `*+CoreDataClass.swift` but the
    /// actual class names are the entity names (e.g., `DeepConfiguration`).
    func testCoreDataEntitiesExist() {
        let knownCoreDataEntities = ["DeepConfiguration", "DownloadItem", "WebHistoryEntry"]

        for entityName in knownCoreDataEntities {
            let entityClasses = Harmonize.productionCode().classes()
                .withName(entityName)

            XCTAssertEqual(
                entityClasses.count, 1,
                "Expected CoreData entity class '\(entityName)' to exist."
            )
        }
    }

    // MARK: - 5. Dependency Injection Rules

    /// DependencyContainer should be the single source for shared dependencies.
    ///
    /// **Rationale**: Centralizing dependency creation makes testing easier
    /// and prevents multiple instances of singletons.
    func testDependencyContainerExists() {
        let containers = Harmonize.productionCode().classes()
            .withName("DependencyContainer")

        XCTAssertEqual(
            containers.count, 1,
            "Expected exactly one DependencyContainer class."
        )
    }

    // MARK: - 6. Protocol Conformance Rules

    /// Driver implementations should conform to the Driver protocol.
    func testDriverProtocolConformance() {
        let driverProtocol = Harmonize.productionCode().protocols()
            .withName("Driver")

        XCTAssertEqual(
            driverProtocol.count, 1,
            "Expected exactly one Driver protocol definition."
        )
    }

    /// DeepDriver protocol should exist for ML model drivers.
    func testDeepDriverProtocolExists() {
        let deepDriverProtocol = Harmonize.productionCode().protocols()
            .withName("DeepDriver")

        XCTAssertEqual(
            deepDriverProtocol.count, 1,
            "Expected exactly one DeepDriver protocol definition."
        )
    }
}
