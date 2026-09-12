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
    /// Consecutive scans that ended with at least one failed metadata load. Cleared on the first
    /// clean scan; at `maximumFailedAttempts` the guards arm anyway so a permanently unloadable
    /// file cannot make every launch re-compile it.
    static let failedAttemptsKey = "aia0478.backfillFailedAttempts"
    static let maximumFailedAttempts = 3

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

    /// Runs each metadata backfill until one clean scan completes. A row with no resolvable file
    /// path remains without a license after this bounded upgrade scan, while a row whose metadata
    /// load throws keeps the guards unarmed so the next launch retries it. Every new import persists
    /// its metadata synchronously and never depends on this scan.
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

        let typeEligibleCount = pending.filter { shouldBackfillType && !$0.modelTypeParsed }.count
        let licenseEligibleCount = pending.filter {
            shouldBackfillLicense && ModelLoadingService.normalizedMetadataString($0.license) == nil
        }.count

        var backfilledTypeCount = 0
        var backfilledLicenseCount = 0
        var loadFailureCount = 0
        // Tracked per row so a failed save can discard exactly what this scan changed. The
        // `viewContext` is shared with live UI and we `await` the loader mid-scan, so unrelated
        // pending edits can accumulate alongside ours.
        var mutatedConfigurations: [DeepConfiguration] = []
        for configuration in pending {
            var rowDidMutate = false
            defer { if rowDidMutate { mutatedConfigurations.append(configuration) } }

            // Normalize a legacy blank even when the source file is no longer available. This
            // keeps persistence consistent with the presentation rule without inventing a license.
            if shouldBackfillLicense,
                ModelLoadingService.normalizedMetadataString(configuration.license) == nil,
                configuration.license != nil {
                configuration.license = nil
                rowDidMutate = true
            }

            // A row whose file can't be resolved (missing/renamed) retains the safe defaults. This
            // is a bounded upgrade scan, not a launch-time retry loop for unavailable user files.
            guard let file = configuration.file else { continue }

            // Re-run the same parser the import path uses. `file` (URL) and `ExtractedModelInfo` are
            // Sendable, so only they cross the actor boundary — the NSManagedObject never leaves the
            // MainActor. One load serves both passes when a row needs them together.
            let info: ExtractedModelInfo
            do {
                info = try await loader.loadAndExtractMetadata(from: file)
            } catch let error as ModelLoadingError where error.isInsufficientMemory {
                // AIA-0889: a memory refusal is deferred work, not evidence the file is unloadable.
                // Counting it would spend this row's permanent-failure budget on a condition that
                // has nothing to do with the model — three launches under pressure would arm the
                // one-shot guards and leave a perfectly good model's type unbackfilled forever.
                LoggingPolicy.warning(
                    "ModelTypeBackfiller: deferring \(file.lastPathComponent) — not enough memory to load it now",
                    logger: .configuration
                )
                continue
            } catch {
                // A failed load (transient compile failure, low disk, brief file-provider outage)
                // must not be mistaken for "nothing to backfill": count it so the one-shot guards
                // stay unarmed and the next launch retries this row.
                loadFailureCount += 1
                LoggingPolicy.error(
                    "ModelTypeBackfiller: metadata load failed for \(file.lastPathComponent); will retry next launch",
                    error: error,
                    logger: .configuration
                )
                continue
            }

            if shouldBackfillType, !configuration.modelTypeParsed, info.typeWasParsed {
                configuration.modelType = info.task   // authoritative value → corrects a stale stored type
                configuration.modelTypeParsed = true
                backfilledTypeCount += 1
                rowDidMutate = true
            }

            if shouldBackfillLicense,
                ModelLoadingService.normalizedMetadataString(configuration.license) == nil {
                if let license = info.license {
                    configuration.license = license
                    backfilledLicenseCount += 1
                    rowDidMutate = true
                }
            }
        }

        if !mutatedConfigurations.isEmpty {
            do {
                try DeepConfiguration.save(in: context)
            } catch {
                // Don't set either guard on a failed save — let the next launch retry. Discard the
                // unsaved mutations so a later unrelated save cannot commit a partial backfill, and
                // surface the failure rather than claiming the one-shot scan completed.
                //
                // Refresh only the rows this scan touched: `context.rollback()` would also discard
                // unrelated pending edits that other main-actor code made on the shared viewContext
                // while we awaited the loader.
                LoggingPolicy.error("ModelTypeBackfiller: save failed; will retry next launch", error: error, logger: .configuration)
                for configuration in mutatedConfigurations {
                    context.refresh(configuration, mergeChanges: false)
                }
                return
            }
        }

        armGuardsIfScanIsComplete(
            loadFailureCount: loadFailureCount,
            shouldBackfillType: shouldBackfillType,
            shouldBackfillLicense: shouldBackfillLicense
        )
        LoggingPolicy.info(
            """
            ModelTypeBackfiller: locked \(backfilledTypeCount) of \(typeEligibleCount) type-pending and \
            licensed \(backfilledLicenseCount) of \(licenseEligibleCount) license-pending model(s); \
            \(loadFailureCount) load failure(s)
            """,
            logger: .configuration
        )
    }

    /// Arms the one-shot guards once a scan is complete enough to never repeat.
    ///
    /// A scan with load failures is incomplete: leaving both guards unarmed makes the next launch
    /// retry the failed rows. Rows are only ever re-parsed, so the retry is idempotent and stays
    /// bounded to still-pending rows. The retry itself is capped, because a file that fails this
    /// many launches is not transiently unavailable — it is corrupt, or no longer loadable on this
    /// OS — and re-compiling it on every launch forever costs a row that will never succeed.
    private func armGuardsIfScanIsComplete(
        loadFailureCount: Int,
        shouldBackfillType: Bool,
        shouldBackfillLicense: Bool
    ) {
        let failedAttempts = loadFailureCount == 0 ? 0 : defaults.integer(forKey: Self.failedAttemptsKey) + 1
        guard loadFailureCount == 0 || failedAttempts >= Self.maximumFailedAttempts else {
            defaults.set(failedAttempts, forKey: Self.failedAttemptsKey)
            return
        }
        if loadFailureCount > 0 {
            LoggingPolicy.warning(
                """
                ModelTypeBackfiller: giving up after \(failedAttempts) scans with load failures; \
                \(loadFailureCount) row(s) keep their defaults
                """,
                logger: .configuration
            )
        }
        if shouldBackfillType {
            defaults.set(true, forKey: Self.defaultsKey)
        }
        if shouldBackfillLicense {
            defaults.set(true, forKey: Self.licenseDefaultsKey)
        }
        defaults.removeObject(forKey: Self.failedAttemptsKey)
    }
}
