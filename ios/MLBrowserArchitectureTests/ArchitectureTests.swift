//
//  ArchitectureTests.swift
//  MLBrowserArchitectureTests
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

    // MARK: - Helpers (source scanning)

    private struct ImportFinding: Hashable {
        let relativePath: String
        let lineNumber: Int
        let line: String
    }

    private struct PatternFinding: Hashable {
        let relativePath: String
        let lineNumber: Int
        let line: String
    }

    private static func repoRootURL() -> URL {
        // #filePath points to .../ios/MLBrowserArchitectureTests/ArchitectureTests.swift
        // Walk up to the repository root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MLBrowserArchitectureTests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repo root
    }

    private static func productionIOSRootURL() -> URL {
        repoRootURL().appendingPathComponent("ios/MLBrowser/iOS", isDirectory: true)
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            files.append(fileURL)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func relativePath(for fileURL: URL) -> String {
        let rootPath = repoRootURL().standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return fileURL.path
    }

    private static func readLines(of fileURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let contents = String(data: data, encoding: .utf8)
        else { return [] }
        return contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func findImports(in fileURL: URL, modules: Set<String>) -> [ImportFinding] {
        let lines = readLines(of: fileURL)
        let relative = relativePath(for: fileURL)
        var findings: [ImportFinding] = []

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("import ") else { continue }
            let module = trimmed.replacingOccurrences(of: "import ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard modules.contains(module) else { continue }
            findings.append(.init(relativePath: relative, lineNumber: idx + 1, line: line))
        }

        return findings
    }

    private static func findLinesMatching(in fileURL: URL, regex pattern: String) -> [PatternFinding] {
        let lines = readLines(of: fileURL)
        let relative = relativePath(for: fileURL)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var findings: [PatternFinding] = []
        for (idx, line) in lines.enumerated() {
            let range = NSRange(location: 0, length: (line as NSString).length)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                findings.append(.init(relativePath: relative, lineNumber: idx + 1, line: line))
            }
        }

        return findings
    }

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

    /// Services should NOT be isolated to MainActor (they can be actors, structs, or classes).
    ///
    /// **Rationale**: Services often do heavy work (networking, file I/O, ML). They should not
    /// default to running on the main actor.
    ///
    /// This rule stays flexible about the exact design (actor vs class), while protecting UI responsiveness.
    func testServicesAreNotMainActor() {
        let root = Self.productionIOSRootURL()
        let files = Self.swiftFiles(under: root)

        // A service type is any top-level actor/class/struct named *Service.
        // We keep the heuristic lightweight to avoid "freezing" on implementation details.
        let serviceTypePattern = #"^\s*(?:public\s+)?(?:final\s+)?(?:actor|class|struct)\s+\w+Service\b"#
        let mainActorPattern = #"^\s*@MainActor\b"#

        guard
            let serviceTypeRegex = try? NSRegularExpression(pattern: serviceTypePattern),
            let mainActorRegex = try? NSRegularExpression(pattern: mainActorPattern, options: [.anchorsMatchLines])
        else {
            XCTFail("Failed to build regex for architecture tests.")
            return
        }

        var offenders: [String] = []

        for fileURL in files {
            let lines = Self.readLines(of: fileURL)
            guard !lines.isEmpty else { continue }

            // Find candidate type lines and check whether @MainActor appears in the few lines above.
            for i in 0..<lines.count {
                let line = lines[i]
                let lineRange = NSRange(location: 0, length: (line as NSString).length)
                guard serviceTypeRegex.firstMatch(in: line, options: [], range: lineRange) != nil else { continue }

                    let lookbackStart = max(0, i - 5)
                    let lookback = lines[lookbackStart...i].joined(separator: "\n")
                    let lookbackRange = NSRange(location: 0, length: (lookback as NSString).length)
                    if mainActorRegex.firstMatch(in: lookback, options: [], range: lookbackRange) != nil {
                        offenders.append("\(Self.relativePath(for: fileURL)):\(i + 1)")
                    }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Service types should not be @MainActor (keep heavy work off the UI thread).
            Offenders:
            \(offenders.sorted().joined(separator: "\n"))

            If a type truly belongs on MainActor, consider renaming to avoid the 'Service' suffix.
            """
        )
    }

    /// ObservableObject classes should have descriptive suffixes indicating their role.
    ///
    /// **Rationale**: Clear naming helps developers understand a type's purpose.
    /// State objects, Managers, and Controllers are common ObservableObject patterns.
    func testObservableObjectsHaveDescriptiveSuffixes() {
        let allowedSuffixes = [
            "State", "Manager", "Controller", "Settings",
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

    /// CoreData entity types should exist (avoid hardcoding a list of entity names, which freezes refactors).
    func testCoreDataEntityTypesExist() {
        let entityClasses = Harmonize.productionCode().classes()
            .filter { $0.inherits(from: "NSManagedObject") }

        XCTAssertGreaterThan(
            entityClasses.count, 0,
            """
            Expected at least one CoreData entity type (NSManagedObject subclass).
            If you intentionally removed CoreData, remove/adjust this rule.
            """
        )
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

    // MARK: - 7. Pragmatic Boundaries (guardrails)

    /// Avoid accidental proliferation of "global state" singletons.
    ///
    /// This rule is intentionally small: it doesn't ban singletons outright, it just makes them explicit.
    func testOnlyApprovedSharedSingletonsExist() {
        let root = Self.productionIOSRootURL()
        let files = Self.swiftFiles(under: root)

        let approvedFiles: Set<String> = [
            "ios/MLBrowser/iOS/State/DependencyContainer.swift",
            "ios/MLBrowser/iOS/UI/EmailController.swift",
            "ios/MLBrowser/iOS/Tools/Reporting/CrashReporter.swift"
        ]

        let sharedPattern = #"\bstatic\s+(?:let|var)\s+shared\b"#

        var offenders: [PatternFinding] = []
        for fileURL in files {
            let rel = Self.relativePath(for: fileURL)
            let findings = Self.findLinesMatching(in: fileURL, regex: sharedPattern)
            guard !findings.isEmpty else { continue }
            guard approvedFiles.contains(rel) else {
                offenders.append(contentsOf: findings)
                continue
            }
        }

        if !offenders.isEmpty {
            let formatted = offenders
                .sorted { ($0.relativePath, $0.lineNumber) < ($1.relativePath, $1.lineNumber) }
                .map { "\($0.relativePath):\($0.lineNumber)  \($0.line.trimmingCharacters(in: .whitespaces))" }
                .joined(separator: "\n")

            XCTFail(
                """
                New `static shared` singletons should be rare and explicitly approved.
                Offenders:
                \(formatted)

                Prefer injecting dependencies via DependencyContainer (or explicit init params) to keep code testable.
                If this singleton is justified, add the file to the allowlist in ArchitectureTests with a comment explaining why.
                """
            )
        }
    }

    /// Privacy invariant (AIA-0392): finding screenshots are written ONLY by `FindingRepository`,
    /// the single auditable on-device write path (images never leave the device except via explicit
    /// user export). Any other PRODUCTION caller of `FindingScreenshotStore.save` is an unreviewed
    /// image-persistence path and fails CI. Tests call it directly, but they live outside the
    /// production root scanned here, so they are not offenders.
    func testOnlyFindingRepositoryWritesScreenshots() {
        let root = Self.productionIOSRootURL()
        let files = Self.swiftFiles(under: root)

        let approvedFiles: Set<String> = [
            "ios/MLBrowser/iOS/State/FindingRepository.swift"
        ]

        // Match the write (`.save`) only — `.delete`/`.load`/`.sweepOrphans` are cleanup/reads, not egress.
        let writePattern = #"FindingScreenshotStore\s*\.\s*save\b"#

        var offenders: [PatternFinding] = []
        for fileURL in files {
            let rel = Self.relativePath(for: fileURL)
            let findings = Self.findLinesMatching(in: fileURL, regex: writePattern)
            guard !findings.isEmpty else { continue }
            guard approvedFiles.contains(rel) else {
                offenders.append(contentsOf: findings)
                continue
            }
        }

        if !offenders.isEmpty {
            let formatted = offenders
                .sorted { ($0.relativePath, $0.lineNumber) < ($1.relativePath, $1.lineNumber) }
                .map { "\($0.relativePath):\($0.lineNumber)  \($0.line.trimmingCharacters(in: .whitespaces))" }
                .joined(separator: "\n")

            XCTFail(
                """
                Finding screenshots must be written only by FindingRepository (AIA-0392) — the single
                auditable on-device write path (images never leave the device except via explicit export).
                Unapproved FindingScreenshotStore.save call sites:
                \(formatted)

                Route the write through FindingRepository, or — if a new writer is genuinely justified —
                add its file to the allowlist here with a comment explaining the privacy review.
                """
            )
        }
    }

    /// Type-based boundary: SwiftUI `View` types should not import CoreData directly.
    ///
    /// This stays refactor-friendly (works regardless of file/folder location).
    /// Marked aspirational initially because some views currently use `@FetchRequest`.
    func testViewTypesAvoidCoreDataImports_Aspirational() {
        XCTExpectFailure(
            """
            Aspirational boundary: View types should not import CoreData directly.
            Prefer: move CoreData queries into state/persistence layer and pass results to views.
            """
        )

        let root = Self.productionIOSRootURL()
        let files = Self.swiftFiles(under: root)

        guard
            let viewTypeRegex = try? NSRegularExpression(
                pattern: #"^\s*(?:public\s+)?(?:struct|class)\s+\w+\s*:\s*View\b"#,
                options: [.anchorsMatchLines]
            )
        else {
            XCTFail("Failed to build View-type regex.")
            return
        }

        var offenders: [String] = []

        for fileURL in files {
            let lines = Self.readLines(of: fileURL)
            guard !lines.isEmpty else { continue }

            let contents = lines.joined(separator: "\n")
            let contentsRange = NSRange(location: 0, length: (contents as NSString).length)
            guard viewTypeRegex.firstMatch(in: contents, options: [], range: contentsRange) != nil else { continue }

            let imports = Self.findImports(in: fileURL, modules: Set(["CoreData"]))
            if !imports.isEmpty {
                let formatted = imports
                    .map { "\($0.relativePath):\($0.lineNumber)  \($0.line.trimmingCharacters(in: .whitespaces))" }
                    .joined(separator: "\n")
                offenders.append(formatted)
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            View-type files importing CoreData:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Type-based boundary: `*State` types should avoid importing SwiftUI/UIKit.
    ///
    /// Marked aspirational because several state types currently import SwiftUI.
    /// Long-term, this helps keep state testable and UI-framework-free.
    func testStateTypesAvoidSwiftUIImports_Aspirational() {
        XCTExpectFailure(
            """
            Aspirational boundary: `*State` types should avoid importing SwiftUI/UIKit.
            Prefer: move SwiftUI-only concerns (e.g. colors, images, property wrappers) to Views or small adapters.
            """
        )

        let root = Self.productionIOSRootURL()
        let files = Self.swiftFiles(under: root)

        guard
            let stateTypeRegex = try? NSRegularExpression(
                pattern: #"^\s*(?:public\s+)?(?:final\s+)?(?:class|actor|struct)\s+\w+State\b"#,
                options: [.anchorsMatchLines]
            )
        else {
            XCTFail("Failed to build State-type regex.")
            return
        }

        var offenders: [String] = []

        for fileURL in files {
            let lines = Self.readLines(of: fileURL)
            guard !lines.isEmpty else { continue }

            let contents = lines.joined(separator: "\n")
            let contentsRange = NSRange(location: 0, length: (contents as NSString).length)
            guard stateTypeRegex.firstMatch(in: contents, options: [], range: contentsRange) != nil else { continue }

            let imports = Self.findImports(in: fileURL, modules: Set(["SwiftUI", "UIKit"]))
            if !imports.isEmpty {
                let formatted = imports
                    .map { "\($0.relativePath):\($0.lineNumber)  \($0.line.trimmingCharacters(in: .whitespaces))" }
                    .joined(separator: "\n")
                offenders.append(formatted)
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            `*State` type files importing SwiftUI/UIKit:
            \(offenders.joined(separator: "\n"))
            """
        )
    }
}
