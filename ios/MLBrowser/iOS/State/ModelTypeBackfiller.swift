//
//  ModelTypeBackfiller.swift
//  AI Archeology
//
//  AIA-0402: one-time backfill of `modelTypeParsed` for models that predate the attribute.
//

import Foundation
import CoreData
import OSLog

/// Re-derives `DeepConfiguration.modelTypeParsed` for rows created before AIA-0402.
///
/// The 0.0.0→0.0.1 migration defaults `modelTypeParsed` to `false` on every existing row, which
/// would make already-imported models look user-editable even when their file declares a type. On
/// the first launch after upgrade this re-runs the metadata parser on each such model: when the
/// parser can decide the type, the row is locked (`modelTypeParsed = true`) and its stored type is
/// corrected to the authoritative value; when it can't, the row is left user-owned (editable) — the
/// safe default.
///
/// Guarded by a one-shot `UserDefaults` flag so the (potentially compile-heavy, for imported
/// models) re-parse runs exactly once. A fresh install has no pre-existing rows — imports set the
/// flag themselves — so this is a no-op there.
@MainActor
final class ModelTypeBackfiller {

    /// One-shot guard key. `false`/absent → run; `true` → already migrated. `false` and absent are
    /// treated identically (both mean "run"), so `bool(forKey:)` is the right read here.
    static let defaultsKey = "aia0402.didBackfillModelTypeParsed"

    private let dataController: DataController
    private let defaults: UserDefaults
    private let loader: ModelLoadingService

    init(
        dataController: DataController,
        defaults: UserDefaults = .standard,
        loader: ModelLoadingService = ModelLoadingService()
    ) {
        self.dataController = dataController
        self.defaults = defaults
        self.loader = loader
    }

    /// Runs the backfill at most once. Cheap to call on every launch — returns immediately once the
    /// guard flag is set.
    func backfillIfNeeded() async {
        guard !defaults.bool(forKey: Self.defaultsKey) else { return }

        let context = dataController.container.viewContext
        // Only rows the migration left `false` need re-deriving; new imports already set it correctly.
        let pending = DeepConfiguration.selectAll(in: context).filter { !$0.modelTypeParsed }

        var backfilledCount = 0
        for configuration in pending {
            // A row whose file can't be resolved (missing/renamed) stays user-owned — the safe default.
            guard let file = configuration.file else { continue }

            // Re-run the same parser the import path uses. `file` (URL) and `ExtractedModelInfo` are
            // Sendable, so only they cross the actor boundary — the NSManagedObject never leaves the
            // MainActor. A load/compile failure leaves the row user-owned rather than aborting the run.
            guard let info = try? await loader.loadAndExtractMetadata(from: file, demo: configuration.demo),
                  info.typeWasParsed else { continue }

            configuration.modelType = info.task   // authoritative value → also corrects a stale stored type
            configuration.modelTypeParsed = true
            backfilledCount += 1
        }

        if backfilledCount > 0 {
            do {
                try DeepConfiguration.save(in: context)
            } catch {
                // Don't set the guard on a failed save — let the next launch retry (the re-parse is
                // idempotent). Surface the failure rather than swallowing it.
                LoggingPolicy.error("ModelTypeBackfiller: save failed; will retry next launch", error: error, logger: .configuration)
                return
            }
        }

        defaults.set(true, forKey: Self.defaultsKey)
        LoggingPolicy.info(
            "ModelTypeBackfiller: locked \(backfilledCount) of \(pending.count) pending model(s)",
            logger: .configuration
        )
    }
}
