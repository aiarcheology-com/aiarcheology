//
//  ModelTypeBackfiller.swift
//  AI Archeology
//
//  AIA-0402: one-time backfill of `modelTypeParsed` for models that predate the attribute.
//

import Foundation
import CoreData
import OSLog

/// Re-derives metadata fields for rows that predate the attributes that persist them.
///
/// The 0.0.0→0.0.1 migration defaults `modelTypeParsed` to `false` on every existing row, which
/// would make already-imported models look user-editable even when their file declares a type. On
/// the first launch after upgrade this re-runs the metadata parser on each such model: when the
/// parser can decide the type, the row is locked (`modelTypeParsed = true`) and its stored type is
/// corrected to the authoritative value; when it can't, the row is left user-owned (editable) — the
/// safe default.
///
/// Each backfill owns a separate one-shot `UserDefaults` flag so adding a new persisted metadata
/// field can scan older rows even after an earlier backfill has completed. A fresh install has no
/// pre-existing rows to fix — new imports persist both fields synchronously — so the method just
/// arms the relevant guards and exits.
@MainActor
final class ModelTypeBackfiller {

    /// One-shot guard key. `false`/absent → run; `true` → already migrated. `false` and absent are
    /// treated identically (both mean "run"), so `bool(forKey:)` is the right read here.
    static let defaultsKey = "aia0402.didBackfillModelTypeParsed"
    /// AIA-0478's independent upgrade pass. It deliberately does not share AIA-0402's key: most
    /// installed configurations have already completed the type pass but still need their license.
    static let licenseDefaultsKey = "aia0478.didBackfillLicense"

    private let dataController: DataController
    private let defaults: UserDefaults
    private let loader: any ModelMetadataLoading

    init(
        dataController: DataController,
        defaults: UserDefaults = .standard,
        loader: any ModelMetadataLoading = ModelLoadingService()
    ) {
        self.dataController = dataController
        self.defaults = defaults
        self.loader = loader
    }

    /// Runs each metadata backfill at most once. AIA-0478 is best-effort: missing or unreadable
    /// legacy files remain without a license after this bounded upgrade scan, while every new import
    /// persists its metadata synchronously.
    func backfillIfNeeded() async {
        let shouldBackfillType = !defaults.bool(forKey: Self.defaultsKey)
        let shouldBackfillLicense = !defaults.bool(forKey: Self.licenseDefaultsKey)
        guard shouldBackfillType || shouldBackfillLicense else { return }

        let context = dataController.container.viewContext
        let pending = DeepConfiguration.selectAll(in: context).filter { configuration in
            let needsType = shouldBackfillType && !configuration.modelTypeParsed
            let needsLicense = shouldBackfillLicense
                && ModelLoadingService.normalizedMetadataString(configuration.license) == nil
            return needsType || needsLicense
        }

        var backfilledTypeCount = 0
        var backfilledLicenseCount = 0
        var didMutate = false
        for configuration in pending {
            // Normalize a legacy blank even when the source file is no longer available. This
            // keeps persistence consistent with the presentation rule without inventing a license.
            if shouldBackfillLicense,
                ModelLoadingService.normalizedMetadataString(configuration.license) == nil,
                configuration.license != nil {
                configuration.license = nil
                didMutate = true
            }

            // A row whose file can't be resolved (missing/renamed) retains the safe defaults. This
            // is a bounded upgrade scan, not a launch-time retry loop for unavailable user files.
            guard let file = configuration.file else { continue }

            // Re-run the same parser the import path uses. `file` (URL) and `ExtractedModelInfo` are
            // Sendable, so only they cross the actor boundary — the NSManagedObject never leaves the
            // MainActor. One load serves both passes when a row needs them together.
            guard let info = try? await loader.loadAndExtractMetadata(from: file, demo: configuration.demo) else {
                continue
            }

            if shouldBackfillType, !configuration.modelTypeParsed, info.typeWasParsed {
                configuration.modelType = info.task   // authoritative value → corrects a stale stored type
                configuration.modelTypeParsed = true
                backfilledTypeCount += 1
                didMutate = true
            }

            if shouldBackfillLicense,
                ModelLoadingService.normalizedMetadataString(configuration.license) == nil {
                if let license = info.license {
                    configuration.license = license
                    backfilledLicenseCount += 1
                    didMutate = true
                }
            }
        }

        if didMutate {
            do {
                try DeepConfiguration.save(in: context)
            } catch {
                // Don't set either guard on a failed save — let the next launch retry. Surface the
                // failure rather than claiming the one-shot scan completed.
                LoggingPolicy.error("ModelTypeBackfiller: save failed; will retry next launch", error: error, logger: .configuration)
                return
            }
        }

        if shouldBackfillType {
            defaults.set(true, forKey: Self.defaultsKey)
        }
        if shouldBackfillLicense {
            defaults.set(true, forKey: Self.licenseDefaultsKey)
        }
        LoggingPolicy.info(
            "ModelTypeBackfiller: locked \(backfilledTypeCount) and licensed \(backfilledLicenseCount) of \(pending.count) pending model(s)",
            logger: .configuration
        )
    }
}
