# Localization recipe (adding / changing L10n strings)

Strings live in a **String Catalog** and are code-generated into `L10n.swift`. Get the workflow
exactly right or you'll either reformat the whole catalog or break the localization test.

Files:
- Catalog: `ios/MLBrowser/iOS/Resources/Localizable.xcstrings` (JSON, `sourceLanguage: en`, ~240 keys).
- Generated: `ios/MLBrowser/iOS/Generated/L10n.swift` — **never hand-edit; it's regenerated.**
- Key allow-list (test): `ios/MLBrowser/iOS/Tools/Localization/LocalizationTestHelpers.swift` → `allKeys`.

## The trap (learned the hard way on AIA-0366)
`Localizable.xcstrings` uses Xcode's JSON style with a **space before the colon** (`"key" : value`)
and special empty-object formatting. A naïve `json.dump(...)` / `sort_keys=True` re-serialization
**reformats all ~19 000 lines** (and re-sorts keys), producing an unreadable diff. **Never round-trip
the whole catalog.** Insert new keys as **surgical text**.

## Recipe

1. **Insert the key as text**, before a unique anchor key, matching the catalog's exact style
   (4-space indent under `strings`, `"key" : value` space-colons). The key **must** include an
   `en` localization — the `xcstrings-to-strings` converter only extracts `sourceLanguage`:

   ```
       "alert.deleteCache.message" : {
         "comment" : "…",
         "extractionState" : "manual",
         "localizations" : {
           "en" : {
             "stringUnit" : { "state" : "translated", "value" : "…English source…" }
           }
         }
       },
   ```
   Other locales are optional (translators fill later; they fall back to `en`). After inserting,
   validate the file still parses:
   `python3 -c "import json;json.load(open('ios/MLBrowser/iOS/Resources/Localizable.xcstrings'))"`,
   and confirm the diff is tiny (`git diff --stat` should show ~12 added lines, not thousands).

2. **Regenerate** `L10n.swift` via the wrapper (do **not** invoke `swiftgen` directly):
   `./scripts/swiftgen.sh generate` (resolves SwiftGen from `~/.local/lib/swiftgen/bin`). Confirm the
   new `L10n.<Group>.<key>` accessor appears and the diff is only the added lines.

3. **Add the key to `StringCatalogValidator.allKeys`** in `LocalizationTestHelpers.swift` (in its
   comment-grouped section), or the localization "no missing keys" test fails.

4. Build to confirm the `L10n.…` reference compiles.

## Reuse first
Prefer existing keys: `L10n.Common.delete`, `L10n.Alert.Warning.title`, `L10n.Alert.*.message`,
`L10n.Settings.*`. Only add a key when the copy is genuinely new (e.g. a destructive-action message
that must state precisely what is deleted).
