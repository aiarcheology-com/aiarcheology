# Localization recipe (adding / changing L10n strings)

Strings live in a **String Catalog** and are code-generated into `L10n.swift`. Get the workflow
exactly right or you'll either reformat the whole catalog or break the localization test.

Files:
- Catalog: `ios/MLBrowser/iOS/Resources/Localizable.xcstrings` (JSON, `sourceLanguage: en`, 425 keys —
  418 authored plus 7 auto-extracted; 17 locales; ~41 000 lines after AIA-0582). System-owned
  strings live in the companion `ios/MLBrowser/iOS/Resources/InfoPlist.xcstrings`; both catalogs
  are covered by the localization gate. Counts drift:
  `python3 scripts/xcstrings_tool.py report` is the source of truth.
- Generated: `ios/MLBrowser/iOS/Generated/L10n.swift` — **never hand-edit; it's regenerated.**
- Key guard (test): `ios/MLBrowserArchitectureTests/LocalizationCatalogTests.swift` derives the
  authored key set from the catalog at test time (AIA-0417) — there is **no** hand-maintained key
  list to update.

## The trap (learned the hard way on AIA-0366)
`Localizable.xcstrings` uses Xcode's JSON style with a **space before the colon** (`"key" : value`)
and special empty-object formatting. A naïve `json.dump(...)` / `sort_keys=True` re-serialization
**reformats the whole file** (and re-sorts keys), producing an unreadable diff. **Never round-trip
the whole catalog** — and note that no serializer can do it faithfully anyway (AIA-0572 measured
both reasons): key order matches neither ASCII (`"/ %@"` sorts before `"%.2f"`) nor Apple's
`JSONSerialization(.sortedKeys)`, and escaping is inconsistent: two `comment` values encode their
em dash as the six-character escape `—`, while every other em dash in the file is stored as a
raw UTF-8 character. No single serializer setting reproduces both forms.

**Use the committed tool — never hand-roll a JSON dump:** `scripts/xcstrings_tool.py`
(`check | report | export | merge | verify`). It splices individual locale blocks by byte span, so
every other byte is preserved by construction. For one or two new keys, surgical text insertion by
hand is still fine.

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

3. Build to confirm the `L10n.…` reference compiles. No key list to update: the
   `LocalizationCatalogTests` guard (`MLBrowserArchitectureTests`) derives the authored key set from
   the catalog itself. It keys off `extractionState : "manual"` (step 1) — a key added via a raw
   `String(localized:)` literal instead of the catalog editor lacks that state, and the guard flags it.

## Reuse first
Prefer existing keys: `L10n.Common.delete`, `L10n.Alert.Warning.title`, `L10n.Alert.*.message`,
`L10n.Settings.*`. Only add a key when the copy is genuinely new (e.g. a destructive-action message
that must state precisely what is deleted).
