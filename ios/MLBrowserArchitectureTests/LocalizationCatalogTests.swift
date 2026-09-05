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

    /// The separate catalog for values that iOS reads directly from Info.plist.
    private static func infoPlistCatalogURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MLBrowserArchitectureTests
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("ios/MLBrowser/iOS/Resources/InfoPlist.xcstrings")
    }

    /// Parses the source `.xcstrings` and returns `(all: every top-level key, manual: the authored
    /// keys)`. Authored keys are those whose top-level entry has `extractionState == "manual"` — the
    /// state Xcode writes for keys added via the String Catalog editor / SwiftGen workflow.
    /// Auto-extracted string literals (for example format fragments) have no `extractionState`.
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
    /// (for example `""`, `"%.2f"`, and interpolation fragments).
    private static func idShapedKeys(in keys: Set<String>) -> Set<String> {
        let predicate = NSPredicate(format: "SELF MATCHES %@", "^[A-Za-z][A-Za-z0-9]*(\\.[A-Za-z0-9_]+)+$")
        return keys.filter { predicate.evaluate(with: $0) }
    }

    /// The authored key set (`extractionState == manual`) must be exactly the id-shaped key set.
    /// Divergence in either direction is real drift the old test could never see.
    func test_sourceCatalog_authoredKeysAreExactlyTheIdShapedKeys() throws {
        let (all, manual) = try Self.parseCatalog()

        // Corruption tripwire: the reader must never silently collapse to an (almost) empty set —
        // that vacuous pass was the AIA-0417 bug. The catalog holds ~418 authored keys.
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

    // MARK: - Translation guards (AIA-0572)
    //
    // These tests are the CI half of the localization contract. The richer authoring checks —
    // CLDR plural categories per locale, entry shape, protected terms — live in
    // `scripts/xcstrings_tool.py verify`, which is the authority when adding translations. The
    // CLDR tables are deliberately NOT mirrored here: duplicating them in two languages invites
    // drift. What CI must catch is the crash class and the regression class, and both are small
    // enough to implement once, natively, with no Python dependency in the test bundle.

    /// The 16 translation targets, in the same casefold order the catalog and
    /// `scripts/xcstrings_tool.py` use — zh-Hans and zh-Hant precede zh-HK.
    private static let targetLocales = [
        "ar", "bn", "cs", "de", "es", "fa", "fr", "he",
        "hi", "hu", "pl", "ru", "uk", "zh-Hans", "zh-Hant", "zh-HK"
    ]

    /// Per-locale count of authored keys carrying a localization across both source catalogs.
    /// Every locale is complete as of AIA-0455 — 414 app strings plus four Info.plist values, with
    /// no fallbacks to English anywhere.
    ///
    /// This is a **ratchet, not a target**: coverage may rise freely and a new English string may
    /// land untranslated, but existing translations may not silently disappear. Deliberately not a
    /// strict-parity gate — that would force 16 translations onto every PR adding one string,
    /// turning a deliberate translation pass into a reflexive one. A new untranslated key does not
    /// reduce these counts, so it still lands; only losing an existing translation trips this.
    ///
    /// Raise these numbers when coverage genuinely improves, which is what locks the gain in.
    ///
    /// **Take the number from this test's own failure message, never from arithmetic or from
    /// `xcstrings_tool.py report`** (AIA-0455). The count below sums *two* catalogs and `report`
    /// prints one, so a baseline derived from it is four too low per locale — and the test would
    /// still pass, silently loosening the ratchet. The previous value proved the hazard is real:
    /// it read 422 while actual coverage was 423, so a fully-translated key had been added without
    /// the gain ever being locked in. 418 records both that gain and AIA-0455's net −5 (six refund
    /// keys plus two replaced keys removed, three fully-translated keys added).
    private static let coverageBaseline = [
        // Unchanged at 418 through AIA-0643. Three support-log strings were replaced rather than
        // reworded, because sealing the export changed what they promise — `support.privacyNote`
        // said the user "will see the whole email", which the encrypted attachment no longer
        // honours, and editing the English in place would have left 16 locales fluently promising
        // the old thing with no gate able to see it (AIA-0455). The replacements were translated
        // into all 16 locales in the same change, so three keys left and three arrived and the
        // floor never moved.
        //
        // 447 at AIA-0654, read from this test's own failure output against a sentinel baseline —
        // never from arithmetic, per the rule above. Only 2 of the 29 points are this ticket's
        // (`import.unsupportedCheckpoint` and `import.unsupportedArchive`, translated into all 16
        // locales alongside the `download.urlHintFormats` replacement, which is net zero). The other
        // 27 were already on `develop`, unlocked: exactly the hazard this comment describes, where a
        // fully-translated key is added and the gain is never recorded. The floor is a single number
        // per locale, so locking this ticket's 2 necessarily locks the 27 with them.
        //
        // 451 at AIA-0666, read the same way — the sentinel run reported `451 localized key(s)` for
        // every one of the 16 locales. All four points are this ticket's: the rejection for a
        // downloaded PyTorch checkpoint stopped being one generic sentence and became four that name
        // what the file describes itself as (`import.checkpointDetector`,
        // `…DetectorUnlabelled`, `…Segmentation`, `…Unrecognized`), each translated into all 16
        // locales in the same change. Nothing was pruned, so the step is exactly the four new keys.
        // Unchanged at 451 through AIA-0757. That ticket replaced `models.empty.message` with
        // `models.empty.messageAddModel` rather than rewording it — the drawer's empty state was
        // telling users to tap a `+` button the ticket removed, and editing the English in place
        // would have left 16 locales fluently promising the old thing (AIA-0455). The replacement
        // was translated into all 16 locales in the same change, so one key left and one arrived
        // and the floor never moved.
        "ar": 451, "bn": 451, "cs": 451, "de": 451,
        "es": 451, "fa": 451, "fr": 451, "he": 451,
        "hi": 451, "hu": 451, "pl": 451, "ru": 451,
        "uk": 451, "zh-HK": 451, "zh-Hans": 451, "zh-Hant": 451
    ]

    /// `%@`, `%lld`, `%1$@`, `%.2f`, `%%`. The length modifier is captured because `%d` and `%lld`
    /// consume different argument widths — treating them as interchangeable would let a translation
    /// misread its argument.
    private static let formatSpecifier = try? NSRegularExpression(
        pattern: "%(?:([0-9]+)\\$)?[-+ #0]*[0-9.*]*((?:hh|h|ll|l|q|z|t|j|L)?)([@diouxXeEfgGcsSpaAn%])"
    )

    /// Normalised specifiers in the order `String(format:)` consumes their arguments: by positional
    /// index when the string uses `%n$`, otherwise by appearance. Equal lists mean two strings
    /// consume the same arguments in the same order. `%%` is a literal percent, not an argument.
    private static func specifiers(in value: String, using regex: NSRegularExpression) -> [String] {
        let range = NSRange(value.startIndex..., in: value)
        var found: [(index: Int?, token: String)] = []
        for match in regex.matches(in: value, range: range) {
            guard let conversionRange = Range(match.range(at: 3), in: value) else { continue }
            let conversion = String(value[conversionRange])
            if conversion == "%" { continue }
            let length = Range(match.range(at: 2), in: value).map { String(value[$0]) } ?? ""
            let position = Range(match.range(at: 1), in: value).flatMap { Int(value[$0]) }
            found.append((position, "%" + length + conversion))
        }
        if found.contains(where: { $0.index != nil }) {
            found.sort { ($0.index ?? 0) < ($1.index ?? 0) }
            // Keep the positional index in the token. Without it "%1$@: %2$@" and "%2$@: %3$@"
            // both reduce to ["%@", "%@"] and compare equal, yet the second reads a third argument
            // that was never passed. Sorting by index still allows a translation to reorder the
            // arguments on screen, which is what positional specifiers exist for.
            return found.map { "\($0.index ?? 0):\($0.token)" }
        }
        return found.map(\.token)
    }

    /// Reduces a localization block to `[variant: value]` so simple strings, plural variations and
    /// device variations can be compared uniformly. A simple string uses the `""` variant.
    private static func flatten(_ localization: [String: Any]) -> [String: String] {
        if let unit = localization["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            return ["": value]
        }
        guard let variations = localization["variations"] as? [String: Any] else { return [:] }
        for kind in ["plural", "device"] {
            guard let group = variations[kind] as? [String: Any] else { continue }
            var out: [String: String] = [:]
            for (variant, raw) in group {
                if let block = raw as? [String: Any],
                   let unit = block["stringUnit"] as? [String: Any],
                   let value = unit["value"] as? String {
                    out[variant] = value
                }
            }
            return out
        }
        return [:]
    }

    /// Every authored key's `localizations` object, keyed by locale.
    private static func parseLocalizations(from url: URL = sourceCatalogURL()) throws -> [String: [String: [String: Any]]] {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: Any] else {
            throw CatalogError.malformed(url)
        }
        var out: [String: [String: [String: Any]]] = [:]
        for (key, value) in strings {
            guard let entry = value as? [String: Any],
                  (entry["extractionState"] as? String) == "manual",
                  let localizations = entry["localizations"] as? [String: Any] else { continue }
            var blocks: [String: [String: Any]] = [:]
            for (locale, raw) in localizations {
                if let block = raw as? [String: Any] { blocks[locale] = block }
            }
            if blocks["en"] != nil { out[key] = blocks }
        }
        return out
    }

    /// The system-facing values extracted from `MLBrowser-Info.plist` and the product settings.
    /// `CFBundleName` is intentionally included: it must be held explicitly in every locale even
    /// though its value is a protected product name.
    private static let infoPlistSourceValues = [
        "NSLocalNetworkUsageDescription": "Your permission is needed to connect with devices on your local network. This allows the app to automatically detect and interact with compatible devices for streamlined data sharing and enhanced functionality.",
        "CFBundleName": "ML Browser",
        "AI Archeology native model graph": "AI Archeology native model graph",
        "ONNX model": "ONNX model",
        "Compiled Core ML model": "Compiled Core ML model"
    ]

    /// Info.plist strings are not generated into `L10n.swift`, so guard their source catalog
    /// directly. This catches a missing UTI description even when all SwiftUI keys are complete.
    func test_infoPlistCatalog_systemFacingValuesAreLocalized() throws {
        let catalog = try Self.parseLocalizations(from: Self.infoPlistCatalogURL())
        XCTAssertEqual(
            Set(catalog.keys), Set(Self.infoPlistSourceValues.keys),
            "InfoPlist catalog keys drifted from the values exposed to the system."
        )

        for (key, english) in Self.infoPlistSourceValues {
            let blocks = try XCTUnwrap(catalog[key], "InfoPlist key '\(key)' is missing.")
            let englishValue = try XCTUnwrap(
                Self.flatten(try XCTUnwrap(blocks["en"], "InfoPlist key '\(key)' has no English source."))[""]
            )
            XCTAssertEqual(englishValue, english, "InfoPlist key '\(key)' has the wrong English source.")

            for locale in Self.targetLocales {
                let block = try XCTUnwrap(blocks[locale], "InfoPlist key '\(key)' is missing '\(locale)'.")
                let value = try XCTUnwrap(
                    Self.flatten(block)[""],
                    "InfoPlist key '\(key)' has an unreadable '\(locale)' block."
                )
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                switch key {
                case "AI Archeology native model graph":
                    XCTAssertTrue(value.contains("AI Archeology"), "Protected product name was translated in '\(locale)'.")
                    XCTAssertNotEqual(value, english, "UTI description '\(key)' is still English in '\(locale)'.")
                case "ONNX model":
                    XCTAssertTrue(value.contains("ONNX"), "Protected format name was translated in '\(locale)'.")
                    XCTAssertNotEqual(value, english, "UTI description '\(key)' is still English in '\(locale)'.")
                case "CFBundleName":
                    XCTAssertEqual(value, english, "CFBundleName must remain identical in '\(locale)'.")
                default:
                    break
                }
            }
        }
    }

    /// A translated value must consume exactly the arguments its English sibling does.
    ///
    /// This is a crash guard, not a style rule: `String(format:)` reads its arguments positionally,
    /// so a translation that adds a specifier reads memory that was never passed, and one that
    /// changes `%lld` to `%d` reads the wrong width.
    func test_sourceCatalog_translationsPreserveFormatSpecifiers() throws {
        let catalog = try Self.parseLocalizations()
        XCTAssertGreaterThan(catalog.count, 100, "Only \(catalog.count) authored key(s) parsed — the reader looks broken.")
        let regex = try XCTUnwrap(Self.formatSpecifier, "The format-specifier pattern failed to compile.")

        var problems: [String] = []
        for (key, blocks) in catalog {
            guard let englishBlock = blocks["en"] else { continue }
            let english = Self.flatten(englishBlock)
            // `values.first` on a Dictionary is not deterministic across runs, which would make a
            // borderline failure appear and vanish between CI runs.
            guard let englishGeneral = english["other"] ?? english[""]
                    ?? english.min(by: { $0.key < $1.key })?.value else { continue }
            let generalSpecifiers = Self.specifiers(in: englishGeneral, using: regex)

            for locale in Self.targetLocales {
                guard let block = blocks[locale] else { continue }
                let translated = Self.flatten(block)
                // A block that is present but yields no variants is malformed. Skipping it here
                // would let a corrupted translation pass CI while still crashing at runtime.
                if translated.isEmpty {
                    problems.append("\(key) [\(locale)]: localization block is present but unreadable")
                    continue
                }
                for (variant, value) in translated {
                    let actual = Self.specifiers(in: value, using: regex)
                    if let englishSibling = english[variant] {
                        let expected = Self.specifiers(in: englishSibling, using: regex)
                        if actual != expected {
                            problems.append("\(key) [\(locale)/\(variant)]: \(actual) != English \(expected)")
                        }
                    } else {
                        // A plural category English does not have (e.g. Czech `few`). It may use
                        // fewer arguments than the general form, never more.
                        var remaining = generalSpecifiers
                        for token in actual {
                            guard let hit = remaining.firstIndex(of: token) else {
                                problems.append(
                                    "\(key) [\(locale)/\(variant)]: \(actual) exceeds English `other` \(generalSpecifiers)")
                                break
                            }
                            remaining.remove(at: hit)
                        }
                    }
                }
            }
        }

        XCTAssertTrue(
            problems.isEmpty,
            """
            \(problems.count) translation(s) do not consume the same arguments as their English source.
            \(problems.sorted().prefix(20).joined(separator: "\n"))
            Fix the values, then re-check with: python3 scripts/xcstrings_tool.py verify
            """
        )
    }

    /// Existing translations must not disappear. Coverage may rise freely.
    func test_sourceCatalog_translationCoverageDoesNotRegress() throws {
        let catalog = try Self.parseLocalizations()
        let infoPlistCatalog = try Self.parseLocalizations(from: Self.infoPlistCatalogURL())

        var regressions: [String] = []
        for locale in Self.targetLocales {
            let present = catalog.values.filter { $0[locale] != nil }.count
                + infoPlistCatalog.values.filter { $0[locale] != nil }.count
            guard let floor = Self.coverageBaseline[locale] else {
                XCTFail("No coverage baseline recorded for '\(locale)'.")
                continue
            }
            if present < floor {
                regressions.append("\(locale): \(present) localized key(s), baseline \(floor)")
            }
        }

        XCTAssertTrue(
            regressions.isEmpty,
            """
            Translation coverage regressed:
            \(regressions.sorted().joined(separator: "\n"))
            These counts are authored keys carrying a localization block for the locale — not the
            percentage `xcstrings_tool.py report` prints, which additionally discounts values still
            identical to English.
            Restore the missing translations, or lower the baseline deliberately if the keys were removed.
            Inspect with: python3 scripts/xcstrings_tool.py report
            """
        )
    }
}
