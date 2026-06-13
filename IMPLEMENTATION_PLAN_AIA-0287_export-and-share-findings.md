# AIA-0287 — Export & share findings

*Adversarially reviewed: 5 grill-master rounds (R1–R4 REVISE, R5 SHIP — ~20 objections resolved or rebutted with code evidence). Reconstructed from the 2026-06-12 grill transcript and re-grounded against current `develop` (AIA-0215 now merged). Codex review pending.*

Issue: [#287](https://github.com/aiarcheology-com/aiarcheology/issues/287) — branch `feature/AIA-0287/export-and-share-findings`, PR → develop.

## Goal

Two share/export paths over the findings inventory built in AIA-0215:

1. **Export** the *currently filtered* findings as a self-contained ZIP (`findings.json` + `findings.csv` + `images/<entityId>.png`), shared via the system share sheet.
2. **Share a single finding** as a composed card image plus the page URL via the system share sheet.

## Load-bearing facts (verified against `develop`)

- `FindingsListView.filteredFindings` is an **in-memory `.filter`** over an `@FetchRequest`, keyed on `\.objectID` (`FindingsListView.swift:79-82`). Any export item source MUST read this same filtered array, not the raw fetch.
- The list already has: trailing dismiss `ToolbarItem(.navigationBarTrailing)` (`:53`), a trailing destructive delete `swipeActions(edge: .trailing)` (`:138`), and a `NavigationLink` per row (`:118`).
- `FindingDetailView` is a `private struct` inside `FindingsListView.swift:204`, with its own trailing toolbar (`:272`) and a `contextMenu` on the page text (`:254`).
- `Finding` content fields are **all optional**: `creationDate_: Date?`, `label_/note_/gps_/detectionClass: String?`, `page: URL?`, `screenshotFilename: String?`; only `entityId: UUID`, `boxX/Y/Width/Height: Double`, `detectionConfidence: Double`, `lifeCycleString: String` are non-optional (`Finding+CoreDataProperties.swift`). `screenshotFilename == "<entityId>.png"`; PNGs live in `Documents/Findings` via `FindingScreenshotStore`.
- `DefaultRenderer.render(_:scale:completionHandler:)` wraps `ImageRenderer`; **`scale` must come from a View's `@Environment(\.displayScale)`** — declaring the property wrapper inside a function returns `1.0` (documented at `DefaultRenderer.swift:20-23`).
- Single `viewContext`. Deployment target iOS 17.6, also iPad-on-Mac. Tests run on the iOS simulator (no `Process` API in-test).

## Implementation

### 1. `State/FindingExporter.swift` — build the ZIP

Input is a `[Snapshot]` of plain **Sendable** value structs, built **synchronously on `@MainActor`** from `filteredFindings` at tap time (Core Data objects never cross actors):

- `Snapshot`: `id = entityId` (the single identity for the zip entry name, the JSON relative path, and the PNG lookup — they must not three-way disagree); optional `label/note/gps/page/detectionClass/date`; `box`; `confidence`; `screenshot` file URL if present.

Background hop:
1. Purge `<tmp>/FindingExports/` (prior exports), then stage `<tmp>/<UUID>/Findings/{images/}`.
2. **Copy images first** to `images/<entityId>.png`, tolerating copy-time missing files (record successes only).
3. Write `findings.json` (Codable, ISO8601 dates, **`null` for nil**, `screenshot` = relative path `images/<entityId>.png` or null) and `findings.csv` (`csvField(_:)` RFC-4180 escaper, **empty field for nil**).
4. Zip via `NSFileCoordinator` `.forUploading`, with the **copy to `<tmp>/FindingExports/Findings-<date>.zip` performed inside the coordinator accessor closure** (the coordinated item is deleted when the accessor returns).
5. Delete the staging dir; return the zip URL.

Staging tree, spelled literally: `<tmp>/<UUID>/Findings/{findings.json, findings.csv, images/<entityId>.png}`.

### 2. Gate tests first (before any UI)

In-test ZIP verification parses the **central directory** (no `Process`/`unzip` in-test):
- mixed case (some PNGs present, some missing),
- all-PNGs-missing case,
- zero-findings case → `[]` json, header-only csv,
- **all-optionals-nil row** case (a present finding whose every optional field is nil → JSON nulls, empty CSV cells).

Plus one **manual `unzip -l`** interop check on the Mac before UI work proceeds (the only non-automated gate).

### 3. `UI/Findings/ActivityShareSheet.swift`

`UIViewControllerRepresentable` over `UIActivityViewController`, presented via `.sheet` (modal — the modal presentation itself guards against concurrent exports). Share contract v1 = plain `[UIImage, URL]` / `[zipURL]`.

### 4. Export entry in `FindingsListView`

- `Button` at the **leading** toolbar slot (`.topBarLeading` / `.navigationBarLeading`, matching the existing trailing dismiss — dismiss stays trailing, no collision).
- Tap → `@MainActor` snapshot of `filteredFindings` → background build with a `ProgressView` state → present sheet with `[zipURL]`.
- Disabled when the filtered list is empty.
- Build failure → alert via the existing L10n error-alert pattern.

### 5. `UI/Findings/FindingShareCard.swift` — the single-finding card

- Fixed-frame card with a fixed image slot: `HighlightedSnapshotView` (or a placeholder when the PNG is missing) + label, page host, date, class + confidence.
- Renders in both color schemes.
- Rendered through the existing `DefaultRenderer.render` with `scale` from the presenting view's `@Environment(\.displayScale)` and the content carrying an explicit `.environment(\.colorScheme, current)` (ImageRenderer ignores ambient environment — every value set explicitly).
- Share items: `page.map { [card, $0] } ?? [card]` (URL omitted when nil).

### 6. Wire single-finding share

- `FindingDetailView`: `ToolbarItemGroup(.navigationBarTrailing) { share; save }` — share added **alongside** the existing Save button, order named.
- List row: share `swipeActions(edge: .leading)` — delete keeps the trailing edge (no ambiguous gesture).
- Row-level `contextMenu` for share (right-click on iPad-on-Mac), distinct from the existing page-text context menu in the detail view.

### 7. Plumbing & tests

- `Testability` ids, L10n keys (`Localizable.xcstrings` + `scripts/swiftgen.sh`), manual pbxproj registration (+ `plutil -lint`).
- Unit tests: JSON shape; CSV adversarial escaping (`a "b", c\r\nd`); filter respected (export reads `filteredFindings`, not the raw fetch); missing-image export + card placeholder; snapshot-then-delete race; the 4 ZIP-structure gate cases from step 2; card pixel-sampling against the card's letterboxed snapshot content rect (same scaled-to-fit math the layout uses).
- Local gates before any push: `scripts/swiftlint.sh`, `scripts/harmonize.sh`, unit tests with an explicit simulator destination. No push without explicit user OK.

## Assumptions

- Personal-inventory scale (tens of findings) — the ZIP build is one brief background hop, not a streamed/batched export.

## Known risks / accepted trade-offs

- `UIActivityViewController` in a `.sheet` on iPad-on-Mac — covered by the manual verification step.
- `ImageRenderer` ignores ambient environment — mitigated by setting every environment value explicitly on the rendered content.
- Plain `[UIImage, URL]` share payload (no `LPLinkMetadata` rich preview) — accepted v1 trade-off; richer preview is a follow-up.
