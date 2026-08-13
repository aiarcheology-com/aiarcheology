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
//  All rules fail closed (AIA-0429): an unreadable file or an empty scan is a rule failure,
//  never a vacuous pass.
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

    /// Semantic (Harmonize) scope aligned with the raw scans' root (`ios/MLBrowser/iOS`).
    ///
    /// `Harmonize.productionCode()` roots at `ios/.harmonize.yaml` and would scan all Swift
    /// under `ios/`, not just the production sources the raw scans cover.
    private static func semanticProductionCode() -> HarmonizeScope {
        Harmonize.on("MLBrowser/iOS")
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

    /// Fail closed: an empty scan means the production root moved or couldn't be enumerated,
    /// which must fail the calling rule rather than let it pass vacuously.
    private static func productionSwiftFiles(file: StaticString = #filePath, line: UInt = #line) -> [URL] {
        let root = productionIOSRootURL()
        let files = swiftFiles(under: root)
        XCTAssertFalse(
            files.isEmpty,
            "Scan found no Swift files under \(root.path) — the scan is broken, not clean.",
            file: file,
            line: line
        )
        return files
    }

    private static func relativePath(for fileURL: URL) -> String {
        let rootPath = repoRootURL().standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return fileURL.path
    }

    /// **Throws when the file can't be read** so the caller fails closed — a read error must
    /// never silently become "no offenders found".
    private static func readLines(of fileURL: URL) throws -> [String] {
        let data = try Data(contentsOf: fileURL)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func findImports(inLines lines: [String], relativePath: String, modules: Set<String>) -> [ImportFinding] {
        var findings: [ImportFinding] = []

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("import ") else { continue }
            let module = trimmed.replacingOccurrences(of: "import ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard modules.contains(module) else { continue }
            findings.append(.init(relativePath: relativePath, lineNumber: idx + 1, line: line))
        }

        return findings
    }

    private static func findLinesMatching(in fileURL: URL, regex pattern: String) throws -> [PatternFinding] {
        let lines = try readLines(of: fileURL)
        let relative = relativePath(for: fileURL)
        let regex = try NSRegularExpression(pattern: pattern)

        var findings: [PatternFinding] = []
        for (idx, line) in lines.enumerated() {
            let range = NSRange(location: 0, length: (line as NSString).length)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                findings.append(.init(relativePath: relative, lineNumber: idx + 1, line: line))
            }
        }

        return findings
    }

    /// Whole-file (not per-line) regex scan, so a call split across lines
    /// (`FindingScreenshotStore\n    .save(...)`, matched by the `\s*` in the pattern) can't slip
    /// through the way per-line matching would. **Throws when the file can't be read** so the caller
    /// fails closed — a read error must never silently become "no offenders found".
    private static func findMatchesInContents(of fileURL: URL, regex pattern: String) throws -> [PatternFinding] {
        let data = try Data(contentsOf: fileURL)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let relative = relativePath(for: fileURL)
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = contents as NSString
        var findings: [PatternFinding] = []
        for match in regex.matches(in: contents, range: NSRange(location: 0, length: ns.length)) {
            let lineNumber = ns.substring(to: match.range.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let lineText = ns.substring(with: ns.lineRange(for: NSRange(location: match.range.location, length: 0)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            findings.append(.init(relativePath: relative, lineNumber: lineNumber, line: lineText))
        }
        return findings
    }

    /// One `LoggingPolicy.<method>(…)` call site: where it is, and the argument text it passes.
    private struct LoggingPolicyCall {
        let finding: PatternFinding
        let arguments: String
    }

    /// Matches a whole `LoggingPolicy.<method>(…)` call, capturing its parenthesised argument
    /// text in group 1. Parentheses are balanced three levels deep — enough for a string
    /// interpolation containing a nested call — which is what keeps the capture confined to one
    /// call: a flat window would either stop short of a wrapped call or run on into the next
    /// statement. `\w+` covers every level (`debug`/`info`/`warning`/`error`/…), because the
    /// invariant is about what is handed to the logger, not which severity it is handed at.
    private static let loggingPolicyCallPattern =
        #"LoggingPolicy\s*\.\s*\w+\s*(\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))"#

    /// Every `LoggingPolicy.<method>(…)` call in the file, paired with its argument text, so a
    /// caller can test what a call *passes* rather than merely that a token appears nearby.
    /// Matching against the captured arguments is what sees a value inside `\(…)` interpolation
    /// — the way an identifier actually reaches a log line.
    ///
    /// **Throws when the file can't be read** so the caller fails closed — a read error must
    /// never silently become "no offenders found".
    private static func findLoggingPolicyCalls(of fileURL: URL) throws -> [LoggingPolicyCall] {
        let data = try Data(contentsOf: fileURL)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let relative = relativePath(for: fileURL)
        let regex = try NSRegularExpression(pattern: loggingPolicyCallPattern)
        let ns = contents as NSString

        var calls: [LoggingPolicyCall] = []
        for match in regex.matches(in: contents, range: NSRange(location: 0, length: ns.length)) {
            let argumentsRange = match.range(at: 1)
            guard argumentsRange.location != NSNotFound else { continue }
            let lineNumber = ns.substring(to: match.range.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let lineText = ns.substring(with: ns.lineRange(for: NSRange(location: match.range.location, length: 0)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            calls.append(
                .init(
                    finding: .init(relativePath: relative, lineNumber: lineNumber, line: lineText),
                    arguments: ns.substring(with: argumentsRange)
                )
            )
        }
        return calls
    }

    /// True when the declaration at `declarationIndex` carries `@MainActor` — on the declaration
    /// line itself, or on attribute lines directly above it (skipping comments and blank lines,
    /// stopping at any other code line so a preceding declaration's attributes are never blamed).
    private static func declarationIsMainActor(lines: [String], declarationIndex: Int) -> Bool {
        if lines[declarationIndex].contains("@MainActor") { return true }
        var index = declarationIndex - 1
        while index >= 0 {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("//") {
                index -= 1
                continue
            }
            guard trimmed.hasPrefix("@") else { break }
            if trimmed.contains("@MainActor") { return true }
            index -= 1
        }
        return false
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
        let stateClasses = Self.semanticProductionCode().classes()
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
    /// Implemented as a raw source scan because Harmonize has no `actor` declaration type, so a
    /// semantic query would miss `actor *Service`. The scan checks the declaration line itself and
    /// the attribute lines directly above it, so same-line attributes are caught and a preceding
    /// declaration's `@MainActor` is never blamed.
    func testServicesAreNotMainActor() throws {
        let files = Self.productionSwiftFiles()

        // A service type is any top-level actor/class/struct named *Service, allowing attributes
        // and access/final modifiers before the keyword (e.g. `@MainActor private final class FooService`).
        let serviceTypePattern = #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|open|final)\s+)*(?:actor|class|struct)\s+\w+Service\b"#
        let serviceTypeRegex = try NSRegularExpression(pattern: serviceTypePattern)

        var offenders: [String] = []

        for fileURL in files {
            let lines: [String]
            do {
                lines = try Self.readLines(of: fileURL)
            } catch {
                XCTFail("Service scan could not read \(Self.relativePath(for: fileURL)): \(error) — failing closed.")
                continue
            }

            for lineIndex in 0..<lines.count {
                let line = lines[lineIndex]
                let lineRange = NSRange(location: 0, length: (line as NSString).length)
                guard serviceTypeRegex.firstMatch(in: line, options: [], range: lineRange) != nil else { continue }

                if Self.declarationIsMainActor(lines: lines, declarationIndex: lineIndex) {
                    offenders.append("\(Self.relativePath(for: fileURL)):\(lineIndex + 1)")
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
            "Renderer", "Download"  // Include project-specific patterns
        ]

        // Filter classes that inherit from ObservableObject
        let allClasses = Self.semanticProductionCode().classes()
        let observableClasses = allClasses.filter { classDecl in
            classDecl.inherits(from: "ObservableObject")
        }

        // Fail closed: this codebase has ObservableObjects; an empty result means the scan broke.
        XCTAssertFalse(
            observableClasses.isEmpty,
            "Expected ObservableObject classes in the codebase — an empty scan means the rule is broken, not clean."
        )

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
        let viewClasses = Self.semanticProductionCode().classes()
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
        let viewStructs = Self.semanticProductionCode().structs()
            .withSuffix("View")

        XCTAssertGreaterThan(
            viewStructs.count, 0,
            "Expected SwiftUI View structs in the codebase."
        )
    }

    // MARK: - 4. Code Organization Rules

    /// CoreData entity types should exist (avoid hardcoding a list of entity names, which freezes refactors).
    func testCoreDataEntityTypesExist() {
        let entityClasses = Self.semanticProductionCode().classes()
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
        let containers = Self.semanticProductionCode().classes()
            .withName("DependencyContainer")

        XCTAssertEqual(
            containers.count, 1,
            "Expected exactly one DependencyContainer class."
        )
    }

    // MARK: - 6. Protocol Conformance Rules

    /// The Driver protocol should exist exactly once (drivers implement it).
    func testDriverProtocolExists() {
        let driverProtocol = Self.semanticProductionCode().protocols()
            .withName("Driver")

        XCTAssertEqual(
            driverProtocol.count, 1,
            "Expected exactly one Driver protocol definition."
        )
    }

    /// DeepDriver protocol should exist for ML model drivers.
    func testDeepDriverProtocolExists() {
        let deepDriverProtocol = Self.semanticProductionCode().protocols()
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
    /// The allowlist is per-declaration (file + approved count), so adding a second singleton to an
    /// already-approved file still fails.
    func testOnlyApprovedSharedSingletonsExist() {
        let files = Self.productionSwiftFiles()

        // Approved singleton declarations: file -> number of approved `static let/var shared`.
        let approvedSingletonCounts: [String: Int] = [
            "ios/MLBrowser/iOS/State/DependencyContainer.swift": 1,  // the composition root itself
            "ios/MLBrowser/iOS/UI/EmailController.swift": 1,
            "ios/MLBrowser/iOS/Tools/Reporting/CrashReporter.swift": 1
        ]

        let sharedPattern = #"\bstatic\s+(?:let|var)\s+shared\b"#

        var offenders: [PatternFinding] = []
        for fileURL in files {
            let rel = Self.relativePath(for: fileURL)
            let findings: [PatternFinding]
            do {
                findings = try Self.findLinesMatching(in: fileURL, regex: sharedPattern)
            } catch {
                XCTFail("Singleton scan could not read \(rel): \(error) — failing closed.")
                continue
            }
            guard !findings.isEmpty else { continue }
            let approvedCount = approvedSingletonCounts[rel] ?? 0
            if findings.count > approvedCount {
                offenders.append(contentsOf: findings.dropFirst(approvedCount))
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
                If this singleton is justified, add its declaration to the per-file counts in
                ArchitectureTests with a comment explaining why.
                """
            )
        }
    }

    /// Privacy invariant (AIA-0392): finding screenshots are written ONLY by `FindingRepository`,
    /// the single auditable on-device write path (images never leave the device except via explicit
    /// user export). Any other PRODUCTION caller of `FindingScreenshotStore.save` is an unreviewed
    /// image-persistence path and fails CI. Tests call it directly, but they live outside the
    /// production root scanned here, so they are not offenders.
    /// Launch-captured flags must be resolved through `LaunchCapturedFlags`, never read straight
    /// off the live snapshot (AIA-0513).
    ///
    /// `FeatureFlagsState` seeds synchronously and the ConfigCat SDK has not synced at composition
    /// time, so `featureFlagsState.snapshot.someFlag` in the composition root captures the compiled
    /// default on *every* launch and the dashboard is inert. That is how the payments kill switch
    /// was silently non-functional from AIA-0350. Unit tests cannot catch a regression here — they
    /// inject the resolved boolean — so this is a static guard on the shape of the code.
    ///
    /// Fails closed: it asserts the file was actually read, so a broken path fails rather than
    /// silently reporting zero offenders.
    func testCompositionRootResolvesLaunchCapturedFlagsThroughTheMirror() {
        let root = Self.repoRootURL()
            .appendingPathComponent("ios/MLBrowser/iOS/State/DependencyContainer.swift")
        guard let source = try? String(contentsOf: root, encoding: .utf8) else {
            return XCTFail("Could not read DependencyContainer.swift — the rule cannot fail closed")
        }
        XCTAssertTrue(source.contains("launchCapturedFlag("),
                      "The composition root should resolve launch-captured flags via launchCapturedFlag(_:)")

        // The only sanctioned direct read is inside the resolver itself, which passes the snapshot
        // to `LaunchCapturedFlags.resolve` as the no-mirror fallback.
        let offenders = source
            .components(separatedBy: .newlines)
            .enumerated()
            .filter { _, line in
                line.contains("featureFlagsState.snapshot.")
                    && !line.contains("//")
            }
            .map { index, line in "DependencyContainer.swift:\(index + 1): \(line.trimmingCharacters(in: .whitespaces))" }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            A launch-captured flag is being read from the unsynced snapshot. Use \
            `launchCapturedFlag(_:)` instead, or the dashboard value will never take effect.
            See AIA-0513.
            Offenders:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    func testOnlyFindingRepositoryWritesScreenshots() {
        // Fail closed: an empty scan means the production root moved or couldn't be enumerated, which
        // would otherwise let this privacy invariant pass vacuously.
        let files = Self.productionSwiftFiles()

        let approvedFiles: Set<String> = [
            "ios/MLBrowser/iOS/State/FindingRepository.swift"
        ]

        // Match the write (`.save`) only — `.delete`/`.load`/`.sweepOrphans` are cleanup/reads, not egress.
        let writePattern = #"FindingScreenshotStore\s*\.\s*save\b"#

        var offenders: [PatternFinding] = []
        for fileURL in files {
            let rel = Self.relativePath(for: fileURL)
            let findings: [PatternFinding]
            do {
                // Whole-file scan (not per-line) so a call split across lines is still caught;
                // a read failure throws and fails the test rather than silently passing.
                findings = try Self.findMatchesInContents(of: fileURL, regex: writePattern)
            } catch {
                XCTFail("Privacy scan could not read \(rel): \(error) — failing closed.")
                continue
            }
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

    /// Privacy invariant (AIA-0437): the raw Clerk account identifier is never passed to
    /// `LoggingPolicy`.
    ///
    /// This is an acceptance criterion, not a style preference. `LoggingPolicy.debug/info/warning/
    /// error` do not only write to OSLog — each one also forwards its message to Sentry as a
    /// breadcrumb (`Observability.recordBreadcrumb`), which is uploaded with any crash or error
    /// event. AIA-0437 requires that the raw identifier never reaches app logs, and puts linking
    /// analytics identity to Sentry explicitly out of scope; a single interpolated
    /// `\(accountIdentifier)` in a log line would do both at once, silently and retroactively.
    ///
    /// The account id may still be *used* — handed to the analytics transport, hashed into an
    /// `appAccountToken`, compared between refreshes. Only the logging edge is closed here, which
    /// is why the scan tests what a `LoggingPolicy` call passes rather than where the identifier
    /// appears.
    ///
    /// The allowlist is empty on purpose: there is no reviewed reason to log this value. Anything
    /// added to it needs a comment explaining the privacy review that approved it.
    func testAccountIdentifierIsNeverLogged() throws {
        // Fail closed: an empty scan means the production root moved or couldn't be enumerated, which
        // would otherwise let this privacy invariant pass vacuously.
        let files = Self.productionSwiftFiles()

        let approvedFiles: Set<String> = []

        // The raw account id as it is spelled at every point it can be read: the `AuthProviding`
        // property, and the Clerk SDK expressions it is derived from. `user?.id` is deliberately
        // loose — it catches `clerk.user?.id` and any other receiver as well.
        let identifierRegex = try NSRegularExpression(
            pattern: #"accountIdentifier|Clerk\s*\.\s*shared\s*\.\s*user\s*\?\s*\.\s*id|user\s*\?\s*\.\s*id"#
        )

        var offenders: [PatternFinding] = []
        var scannedCalls = 0
        for fileURL in files {
            let rel = Self.relativePath(for: fileURL)
            let calls: [LoggingPolicyCall]
            do {
                calls = try Self.findLoggingPolicyCalls(of: fileURL)
            } catch {
                XCTFail("Account-identifier log scan could not read \(rel): \(error) — failing closed.")
                continue
            }
            scannedCalls += calls.count
            guard approvedFiles.contains(rel) == false else { continue }
            for call in calls {
                let range = NSRange(location: 0, length: (call.arguments as NSString).length)
                guard identifierRegex.firstMatch(in: call.arguments, range: range) != nil else { continue }
                offenders.append(call.finding)
            }
        }

        // Second fail-closed guard, on the scan itself rather than the file list: the rule can only
        // report offenders among the calls it managed to parse, so a call regex that silently stopped
        // matching would make this pass with zero findings for entirely the wrong reason.
        XCTAssertGreaterThan(
            scannedCalls,
            0,
            "Found no LoggingPolicy call sites to inspect — the scan is broken, not clean."
        )

        if !offenders.isEmpty {
            let formatted = offenders
                .sorted { ($0.relativePath, $0.lineNumber) < ($1.relativePath, $1.lineNumber) }
                .map { "\($0.relativePath):\($0.lineNumber)  \($0.line.trimmingCharacters(in: .whitespaces))" }
                .joined(separator: "\n")

            XCTFail(
                """
                The raw Clerk account identifier must never be passed to LoggingPolicy (AIA-0437).
                LoggingPolicy.debug/info/warning/error forward the message to Sentry as a breadcrumb,
                so logging it would put the account id in crash reports — which the ticket rules out.
                Offending log call sites:
                \(formatted)

                Log something non-identifying instead (a state name, a bool, a count). If a call site
                is genuinely justified, add its file to the allowlist here with a comment explaining
                the privacy review that approved it.
                """
            )
        }
    }

    /// Type-based boundary: SwiftUI `View` types should not import CoreData directly.
    ///
    /// This stays refactor-friendly (works regardless of file/folder location).
    ///
    /// Ratchet mechanism (AIA-0429): `legacyOffenders` is the frozen debt list. A NEW offender
    /// fails immediately; cleaning a baseline file up also fails until it is removed from the
    /// baseline, so the list can only shrink. When it reaches empty, delete the baseline and let
    /// the rule enforce unconditionally.
    func testViewTypesAvoidCoreDataImports_Aspirational() throws {
        let legacyOffenders: Set<String> = [
            "ios/MLBrowser/iOS/UI/Catalog/CatalogBrowseView.swift",
            "ios/MLBrowser/iOS/UI/Drawer/DrawerContent.swift",
            "ios/MLBrowser/iOS/UI/Findings/FindingsListView.swift",
            "ios/MLBrowser/iOS/UI/Findings/SaveFindingSheet.swift",
            "ios/MLBrowser/iOS/UI/LocationSheetView.swift"
        ]

        let files = Self.productionSwiftFiles()
        let viewTypeRegex = try NSRegularExpression(
            pattern: #"^\s*(?:public\s+)?(?:struct|class)\s+\w+\s*:\s*View\b"#,
            options: [.anchorsMatchLines]
        )

        var offenders: Set<String> = []

        for fileURL in files {
            let rel = Self.relativePath(for: fileURL)
            let lines: [String]
            do {
                lines = try Self.readLines(of: fileURL)
            } catch {
                XCTFail("View/CoreData scan could not read \(rel): \(error) — failing closed.")
                continue
            }
            guard !lines.isEmpty else { continue }

            let contents = lines.joined(separator: "\n")
            let contentsRange = NSRange(location: 0, length: (contents as NSString).length)
            guard viewTypeRegex.firstMatch(in: contents, options: [], range: contentsRange) != nil else { continue }

            if !Self.findImports(inLines: lines, relativePath: rel, modules: ["CoreData"]).isEmpty {
                offenders.insert(rel)
            }
        }

        let newOffenders = offenders.subtracting(legacyOffenders)
        XCTAssertTrue(
            newOffenders.isEmpty,
            """
            New View-type files importing CoreData (not in the legacy baseline):
            \(newOffenders.sorted().joined(separator: "\n"))

            Prefer: move CoreData queries into the state/persistence layer and pass results to views.
            """
        )

        let cleaned = legacyOffenders.subtracting(offenders)
        XCTAssertTrue(
            cleaned.isEmpty,
            """
            Baseline entries are now clean — remove them from legacyOffenders in this test to ratchet down:
            \(cleaned.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Type-based boundary: `*State` types should avoid importing SwiftUI/UIKit.
    ///
    /// Long-term, this helps keep state testable and UI-framework-free.
    ///
    /// Ratchet mechanism (AIA-0429): same as `testViewTypesAvoidCoreDataImports_Aspirational` —
    /// the baseline only shrinks; new offenders fail immediately.
    func testStateTypesAvoidSwiftUIImports_Aspirational() throws {
        let legacyOffenders: Set<String> = [
            "ios/MLBrowser/iOS/State/Appstate.swift",
            "ios/MLBrowser/iOS/State/DeepState.swift",
            "ios/MLBrowser/iOS/UI/Tour/TourState.swift"
        ]

        let files = Self.productionSwiftFiles()
        let stateTypeRegex = try NSRegularExpression(
            pattern: #"^\s*(?:public\s+)?(?:final\s+)?(?:class|actor|struct)\s+\w+State\b"#,
            options: [.anchorsMatchLines]
        )

        var offenders: Set<String> = []

        for fileURL in files {
            let rel = Self.relativePath(for: fileURL)
            let lines: [String]
            do {
                lines = try Self.readLines(of: fileURL)
            } catch {
                XCTFail("State/SwiftUI scan could not read \(rel): \(error) — failing closed.")
                continue
            }
            guard !lines.isEmpty else { continue }

            let contents = lines.joined(separator: "\n")
            let contentsRange = NSRange(location: 0, length: (contents as NSString).length)
            guard stateTypeRegex.firstMatch(in: contents, options: [], range: contentsRange) != nil else { continue }

            if !Self.findImports(inLines: lines, relativePath: rel, modules: ["SwiftUI", "UIKit"]).isEmpty {
                offenders.insert(rel)
            }
        }

        let newOffenders = offenders.subtracting(legacyOffenders)
        XCTAssertTrue(
            newOffenders.isEmpty,
            """
            New `*State` type files importing SwiftUI/UIKit (not in the legacy baseline):
            \(newOffenders.sorted().joined(separator: "\n"))

            Prefer: move SwiftUI-only concerns (e.g. colors, images, property wrappers) to Views or small adapters.
            """
        )

        let cleaned = legacyOffenders.subtracting(offenders)
        XCTAssertTrue(
            cleaned.isEmpty,
            """
            Baseline entries are now clean — remove them from legacyOffenders in this test to ratchet down:
            \(cleaned.sorted().joined(separator: "\n"))
            """
        )
    }

    // MARK: - The free-days confirmation cannot be bypassed (AIA-0623)

    /// Subscribing while the app-managed free window is still open forfeits whatever is left of it —
    /// the window and Apple's introductory trial do not stack, and the trial cannot be deferred. So a
    /// purchase started from an open window must pass through a confirmation first.
    ///
    /// **This rule exists because nothing else can check it.** The paywall's Subscribe button needs a
    /// real StoreKit `Product`, and `MockSubscriptionProvider` has none, so no UI test can render the
    /// button — let alone the dialog behind it. `PaywallPurchaseIntentTests` proves the decision is
    /// *correct*; only this proves it is *reached*. A unit test on an enum nothing calls passes
    /// forever.
    ///
    /// Three claims, each closing a different way the feature could ship dead:
    ///
    /// 1. **One purchase call site.** A second route to `SubscriptionState.purchase` is a route that
    ///    never sees the confirmation. Deliberately spelled as the receiver the app actually uses;
    ///    that is a real limitation (`state.purchase(…)` under another name would evade it), which is
    ///    why it is only one of the three and not the whole rule.
    /// 2. **The decision is consulted.** Deleting the `switch` in the button leaves every other test
    ///    in the suite green.
    /// 3. **The one live presentation is wired.** `PaywallView.freeAccessDaysRemaining` has no
    ///    default, so the compiler forces both call sites to answer — but the cheapest answer that
    ///    compiles is `{ nil }`, which ships the feature dead on the only path that can ever run it.
    ///    The Settings sheet is that path, so the accessor has to reach it from `DrawerContent`.
    func testThePurchasePathCannotBypassTheFreeDaysConfirmation() throws {
        // Fail closed: an empty scan means the production root moved, not that the rule is satisfied.
        let files = Self.productionSwiftFiles()

        var purchaseCallSites: [String] = []
        var paywallConsultsTheDecision = false
        var settingsRouteIsWired = false
        var sawPaywall = false
        var sawDrawer = false

        for fileURL in files {
            let rel = Self.relativePath(for: fileURL)
            let source: String
            do {
                source = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                XCTFail("Free-days confirmation scan could not read \(rel): \(error) — failing closed.")
                continue
            }

            // Comment lines are dropped before every check below. Without that, this whole rule is
            // satisfiable by prose: a regression that deletes the `switch` but leaves the sentence
            // "…decided by `PaywallPurchaseIntent.resolve(…)`" in a doc comment would keep it green,
            // and the comments here are deliberately long. Line comments only — that is what these
            // files use, and a block-comment parser would be more machinery than the rule is worth.
            let code = source
                .components(separatedBy: .newlines)
                .enumerated()
                .filter { $0.element.trimmingCharacters(in: .whitespaces).hasPrefix("//") == false }

            for (offset, line) in code where line.contains("subscriptionState.purchase(") {
                purchaseCallSites.append("\(rel):\(offset + 1)")
            }

            let codeText = code.map(\.element).joined(separator: "\n")

            if rel.hasSuffix("UI/Subscription/PaywallView.swift") {
                sawPaywall = true
                paywallConsultsTheDecision = codeText.contains("PaywallPurchaseIntent.resolve(")
            }

            if rel.hasSuffix("UI/Drawer/DrawerContent.swift") {
                sawDrawer = true
                settingsRouteIsWired = codeText.contains("windowDaysRemaining")
            }
        }

        // Fail closed on the scan itself: if either file were renamed or moved, the two flags below
        // would be false for the wrong reason, and the failure message would send a reader hunting a
        // bug that does not exist.
        XCTAssertTrue(sawPaywall, "PaywallView.swift was not found by the scan — the rule is broken, not violated.")
        XCTAssertTrue(sawDrawer, "DrawerContent.swift was not found by the scan — the rule is broken, not violated.")

        // Asserted as a count plus a path, never against a list rebuilt from the findings: an
        // "expected" value derived from the actual one is satisfied by whatever it is handed.
        XCTAssertEqual(
            purchaseCallSites.count,
            1,
            """
            `SubscriptionState.purchase` must be called from exactly one place — `PaywallView`'s \
            `startPurchase(_:)`, which is reached only after `PaywallPurchaseIntent.resolve` has \
            decided whether the user's remaining free days need confirming first (AIA-0623).

            Found: \(purchaseCallSites.joined(separator: ", "))

            A second call site is a route that spends someone's free window without telling them. \
            Route the new path through `startPurchase(_:)` instead of calling `purchase` directly.
            """
        )

        XCTAssertTrue(
            purchaseCallSites.first?.hasPrefix("ios/MLBrowser/iOS/UI/Subscription/PaywallView.swift:") == true,
            """
            The one `SubscriptionState.purchase` call site has moved out of `PaywallView` \
            (AIA-0623): it is now at \(purchaseCallSites.first ?? "nowhere"). The confirmation lives \
            in `PaywallView`, so a purchase committed anywhere else does not pass through it.
            """
        )

        XCTAssertTrue(
            paywallConsultsTheDecision,
            """
            `PaywallView` no longer references `PaywallPurchaseIntent.resolve` (AIA-0623), so the \
            Subscribe button is committing money without asking whether an open free-access window \
            would be forfeited. `PaywallPurchaseIntentTests` cannot catch this: it tests the \
            decision, not whether anything calls it.
            """
        )

        XCTAssertTrue(
            settingsRouteIsWired,
            """
            `DrawerContent` no longer passes `freeAccess.windowDaysRemaining` into `SettingsForm` \
            (AIA-0623). The Settings sheet is the *only* presentation that can be reached while a \
            window is open, so without it `PaywallView.freeAccessDaysRemaining` always answers `nil`, \
            the confirmation never appears, and every other test in this suite still passes.
            """
        )
    }
}
