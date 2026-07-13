//
//  LocalizationCatalogTests.swift
//  MLBrowserArchitectureTests
//
//  AIA-0417: guard the localization String Catalog against key drift.
//
//  This lives in the macOS-hosted arch-test target (not the iOS-Simulator unit target) because it
//  reads the SOURCE `.xcstrings` via `#filePath` + `Data(contentsOf:)`. The unit target runs
//  sandboxed on the simulator and cannot read repo source — see scripts/harmonize.sh (which
//  documents the App-Sandbox failure) and the sibling ArchitectureTests.swift, which reads repo
//  source the same way.
//

import Foundation
import XCTest

/// Validates the app's source String Catalog (`Localizable.xcstrings`) — the single source of truth
/// for localization keys.
///
/// Replaces the former hand-maintained `StringCatalogValidator.allKeys` mirror (AIA-0417). That
/// mirror drifted silently because the test meant to guard it read the *compiled* app bundle, where
/// Xcode has already compiled `.xcstrings` into per-locale `.strings` — the raw catalog is absent,
/// so the lookup returned `nil`, the key set was empty, and the assertion passed vacuously. Reading
/// the source catalog here removes the drift class entirely.
final class LocalizationCatalogTests: XCTestCase {

    private enum CatalogError: Error, CustomStringConvertible {
        case fileNotFound(URL)
        case unreadable(URL, underlying: Error)
        case malformed(URL)

        var description: String {
            switch self {
            case .fileNotFound(let url):
                return "String Catalog not found at \(url.path)"
            case .unreadable(let url, let error):
                return "String Catalog unreadable at \(url.path): \(error)"
            case .malformed(let url):
                return "String Catalog malformed (no top-level `strings` object) at \(url.path)"
            }
        }
    }

    /// The source catalog, located relative to this test file.
    /// `#filePath` → `.../ios/MLBrowserArchitectureTests/LocalizationCatalogTests.swift`.
    private static func sourceCatalogURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MLBrowserArchitectureTests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("ios/MLBrowser/iOS/Resources/Localizable.xcstrings")
    }

    /// Parses the source `.xcstrings` and returns `(all: every top-level key, manual: the authored
    /// keys)`. Authored keys are those whose top-level entry has `extractionState == "manual"` — the
    /// state Xcode writes for keys added via the String Catalog editor / SwiftGen workflow.
    /// Auto-extracted string literals (e.g. `"%.2f"`, `"Loading..."`) have no `extractionState`.
    ///
    /// Only the TOP-LEVEL `strings` keys are localization keys. Do **not** recurse into an entry's
    /// `localizations` / `stringUnit` / `variations`: the `state` values nested there are per-unit
    /// *translation* states, not keys.
    ///
    /// **Throws** on any read/parse failure. A broken read must fail the test loudly — never collapse
    /// to an empty set that passes vacuously (that silent-empty path was the AIA-0417 bug).
    private static func parseCatalog() throws -> (all: Set<String>, manual: Set<String>) {
        let url = sourceCatalogURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CatalogError.fileNotFound(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CatalogError.unreadable(url, underlying: error)
        }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let root = json as? [String: Any],
              let strings = root["strings"] as? [String: Any] else {
            throw CatalogError.malformed(url)
        }

        var all: Set<String> = []
        var manual: Set<String> = []
        for (key, value) in strings {
            all.insert(key)
            if let entry = value as? [String: Any],
               (entry["extractionState"] as? String) == "manual" {
                manual.insert(key)
            }
        }
        return (all, manual)
    }

    /// Keys matching the app's stable-identifier convention: a dot-namespaced identifier
    /// (`history.title`, `browser.location.dataSheet.deleteCookies`). Excludes auto-extraction noise
    /// (`""`, `"%.2f"`, `"Add Model"`, `"Loading..."`, …).
    private static func idShapedKeys(in keys: Set<String>) -> Set<String> {
        let predicate = NSPredicate(format: "SELF MATCHES %@", "^[A-Za-z][A-Za-z0-9]*(\\.[A-Za-z0-9_]+)+$")
        return keys.filter { predicate.evaluate(with: $0) }
    }

    /// The authored key set (`extractionState == manual`) must be exactly the id-shaped key set.
    /// Divergence in either direction is real drift the old test could never see.
    func test_sourceCatalog_authoredKeysAreExactlyTheIdShapedKeys() throws {
        let (all, manual) = try Self.parseCatalog()

        // Corruption tripwire: the reader must never silently collapse to an (almost) empty set —
        // that vacuous pass was the AIA-0417 bug. The catalog holds ~240 authored keys.
        XCTAssertGreaterThan(
            manual.count, 100,
            "Only \(manual.count) authored key(s) parsed from the source catalog — the reader looks broken."
        )

        // Primary invariant. Two independent derivations of "the real keys" must agree:
        //  - id-shaped but NOT manual → a real key lost its `manual` state (e.g. added via a raw
        //    `String(localized:)` literal, bypassing the catalog-editor / SwiftGen workflow).
        //  - manual but NOT id-shaped → an authored key violates the stable-identifier convention.
        let idShaped = Self.idShapedKeys(in: all)
        XCTAssertEqual(
            manual, idShaped,
            """
            Localization key drift between authored (extractionState == "manual") and id-shaped keys.
            Only-authored (manual, not id-shaped): \(manual.subtracting(idShaped).sorted())
            Only-id-shaped (id-shaped, not manual): \(idShaped.subtracting(manual).sorted())
            Fix: author keys via the String Catalog editor (so they carry extractionState == "manual")
            and follow the dot-namespaced convention. See references/localization.md.
            """
        )

        // Cross-feature presence sample: a wholesale key deletion would keep the two sets equal
        // (both shrink together), so assert a few well-known keys across features still exist.
        let expected = [
            "history.title", "common.done", "models.title",
            "auth.signOut", "settings.title", "download.title"
        ]
        for key in expected {
            XCTAssertTrue(
                manual.contains(key),
                "Expected authored key '\(key)' missing from the source catalog."
            )
        }
    }
}
