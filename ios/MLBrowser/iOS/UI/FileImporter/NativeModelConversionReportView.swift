//
//  NativeModelConversionReportView.swift
//  AI Archeology
//
//  User-visible, app-owned presentation of a durable conversion report.
//

import SwiftUI
import UniformTypeIdentifiers
import NativeModelConverter

/// Presents a path-free support and recovery report written by the host app, modally.
///
/// Wraps ``NativeModelConversionReportContent`` in its own navigation stack and adds the Done
/// button a sheet needs. Push the *content* view instead when the log is reached from a screen
/// that already has a navigation stack (the Configuration sheet's Conversion Log row).
struct NativeModelConversionReportView: View {
	@Environment(\.dismiss) private var dismiss
	let report: NativeModelConversionImportReport
	let isPreparingExport: Bool
	/// Whether a converted model is actually on disk to export right now.
	let canExport: Bool
	let onExport: () -> Void

	init(
		report: NativeModelConversionImportReport,
		isPreparingExport: Bool = false,
		canExport: Bool = false,
		onExport: @escaping () -> Void = {}
	) {
		self.report = report
		self.isPreparingExport = isPreparingExport
		self.canExport = canExport
		self.onExport = onExport
	}

	var body: some View {
		NavigationStack {
			NativeModelConversionReportContent(
				report: report,
				isPreparingExport: isPreparingExport,
				canExport: canExport,
				onExport: onExport
			)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button(L10n.Common.done) {
						dismiss()
					}
					.fontWeight(.semibold)
					.tint(.blue)
				}
			}
		}
	}
}

/// Sends a conversion report to support, from wherever the user asked to report it (AIA-0778).
///
/// Free of the view so the failure alert can report without first pushing the log: the ticket is
/// about the *path* being clear, and a path that begins "open the log, then find a toolbar menu" is
/// the one it was raised against. The log view and the alert therefore send the identical text.
enum NativeModelConversionReporting {
	/// A plain-text rendering of the report. Like the on-screen report it records no user document
	/// location: the source *filename* identifies the model (AIA-0778), never where it was read from.
	static func logText(for report: NativeModelConversionImportReport) -> String {
		var lines = [
			"AI Archeology — Native Model Conversion Log",
			"Model file: \(report.sourcePackageFilename)",
			"Acquired: \(report.wasRemoteImport ? "remote link" : "local file")",
			"State: \(report.state.rawValue)",
			"Converter: \(report.nativeConverterPackageVersion) (revision \(report.nativeConverterConversionRevision))"
		]
		if let diagnostic = report.diagnostic {
			lines += [
				"",
				"Diagnostic:",
				"  Code: \(diagnostic.code)",
				"  Phase: \(diagnostic.phase.rawValue)",
				"  Message: \(diagnostic.message)"
			]
		}
		// Listed before `metrics` and independently of it: a failed conversion has no metrics at
		// all, and these are what a support reader can still use (AIA-0778). The byte count is
		// printed both exactly and in units — the exact number is what gets compared against a
		// limit, the readable one is what a human reacts to.
		if let sourceByteCount = report.sourceByteCount {
			let readable = ByteCountFormatter.string(
				fromByteCount: Int64(clamping: sourceByteCount),
				countStyle: .file
			)
			lines += ["", "Source bytes: \(sourceByteCount) (\(readable))"]
		}
		// Remote imports only; never a local path. See ``NativeModelConversionImportReport/sourceURL``.
		if let sourceURL = report.sourceURL {
			lines.append("Source URL: \(sourceURL)")
		}
		if let metrics = report.metrics {
			lines += [
				"",
				"Metrics:",
				"  Input bytes: \(metrics.sourceFootprint.totalByteCount)",
				"  Output bytes: \(metrics.emission.outputModelByteCount)",
				"  Operations: \(metrics.emission.operationCount)"
			]
		}
		lines += ["", "Events:"]
		for entry in report.entries {
			var parts = [entry.state.rawValue]
			if let progress = entry.progress {
				parts.append(progressDescription(progress))
			}
			if let diagnostic = entry.diagnostic {
				parts.append("\(diagnostic.code): \(diagnostic.message)")
			}
			let timestamp = entry.timestamp.formatted(date: .abbreviated, time: .standard)
			lines.append("  \(timestamp) — \(parts.joined(separator: " · "))")
		}
		return lines.joined(separator: "\n")
	}

	static func subject() -> String {
		"\(L10n.Support.title) — \(L10n.Import.conversionLog)"
	}

	/// Where ``exportedLogFile(for:)`` writes the file it hands to `ShareLink`. Inside the app's
	/// temporary directory: sandboxed, and purged by the system. The same shape as
	/// `SupportRequestView`'s `support-log-export`, which is the one share in this app proven to
	/// survive *Save to Files* on macOS.
	private static var logExportDirectory: URL {
		FileManager.default.temporaryDirectory
			.appendingPathComponent("conversion-log-export", isDirectory: true)
	}

	/// The log as a **named file on disk**, or `nil` if it could not be written.
	///
	/// Three shapes were tried against macOS's Save-to-Files service before this one, and every
	/// failure ended identically: `SHKSaveToFilesSharingService` could not resolve the item, called
	/// `-[NSSavePanel setNameFieldStringValue:]` with `nil`, and AppKit raised
	/// `NSInternalInconsistencyException` from inside ShareKit — terminating the app where no
	/// `do/catch` of ours can see it (AIA-0778).
	///
	/// 1. `ShareLink(item: someString)` — UIKit spills the string to an anonymous `text.txt`;
	///    *"No eligible items to save"*, because there is no name to save it under.
	/// 2. `DataRepresentation` + `suggestedFileName` — correctly *named*, and still
	///    *"No eligible items to save"*: the service wants a file it can resolve, not bytes.
	/// 3. A file URL whose directory was deleted and recreated on every call — *"Save: timed out
	///    loading URL"*. This view is instantiated more than once, so a re-render removed the file
	///    while the share sheet was still loading it.
	///
	/// Hence the two rules here, both learned the hard way: hand over a **file URL**, and **never
	/// remove one that a share may still be holding**. A superseded export is left to the system's
	/// purge of the temporary directory rather than deleted underneath a share in flight — a stale
	/// file nobody is reading costs nothing, and deleting a live one costs the whole app.
	static func exportedLogFile(for report: NativeModelConversionImportReport) -> URL? {
		let directory = logExportDirectory
		let file = directory.appendingPathComponent(exportFilename(for: report), isDirectory: false)
		let text = logText(for: report)
		do {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
			// Rewritten only when the contents actually differ, so the repeated calls this view
			// makes do not churn a file the share sheet may be reading.
			if let existing = try? String(contentsOf: file, encoding: .utf8), existing == text {
				return file
			}
			try text.write(to: file, atomically: true, encoding: .utf8)
			return file
		} catch {
			// `nil` rather than a throw: the caller's only recourse is to leave the row out, and a
			// Share button pointing at a file that was never written is worse than no button.
			LoggingPolicy.warning("Could not write the conversion log for sharing: \(error)", logger: .ui)
			return nil
		}
	}

	/// `<model>-conversion-log.txt`, from a **sanitised** stem.
	///
	/// `sourcePackageFilename` is the name of a file the user chose, so it is untrusted for this
	/// purpose: a `/` or a `..` in it would place the export outside the directory above. Only
	/// alphanumerics, dashes and underscores survive; anything else becomes a dash, and a stem that
	/// sanitises away to nothing falls back rather than producing a dotfile or a bare extension.
	static func exportFilename(for report: NativeModelConversionImportReport) -> String {
		let stem = (report.sourcePackageFilename as NSString).deletingPathExtension
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
		let sanitised = String(
			stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
		)
		.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
		.prefix(60)
		let name = sanitised.isEmpty ? "model" : String(sanitised)
		// The configuration id makes the name unique per report. Without it, two conversions of the
		// same model — or two names that sanitise to the same stem — share one file, and the second
		// write replaces one the first report's share may still be loading. The stem alone is not
		// an identity.
		let identity = report.configurationID.uuidString.prefix(8).lowercased()
		return "\(name)-\(identity)-conversion-log.txt"
	}

	/// The app's support-mail tiers: the in-app composer, then the user's default mail app. Both are
	/// user-driven — nothing here sends anything on its own.
	///
	/// - Returns: whether a draft was actually opened. A device with no mail account *and* no mail
	///   app reaches neither tier, and `EmailController`'s own contract asks callers to handle that
	///   rather than leave a button that does nothing when pressed. The log view has a Share item
	///   beside this one; the failure alert has to offer the log instead.
	@MainActor
	@discardableResult
	static func email(_ report: NativeModelConversionImportReport) async -> Bool {
		let body = logText(for: report)
		do {
			try EmailController.shared.sendEmail(
				subject: subject(),
				body: body,
				to: SupportRequest.supportEmailAddress
			)
			return true
		} catch {
			LoggingPolicy.warning("Mail composer unavailable (\(error)) — falling back to mailto:", logger: .ui)
			return await EmailController.shared.openMailto(
				subject: subject(),
				body: body,
				to: SupportRequest.supportEmailAddress
			)
		}
	}

	static func progressDescription(_ progress: NativeModelConversionProgress) -> String {
		var values = [progress.phase.rawValue]
		if progress.totalUnitCount > 0 {
			values.append("\(progress.completedUnitCount)/\(progress.totalUnitCount)")
		}
		if let operationName = progress.operationName {
			values.append(operationName)
		}
		return values.joined(separator: " · ")
	}
}

/// The report itself, without a navigation container — pushable onto an existing stack.
///
/// This view deliberately reads no model or user-document paths. The report's protocol values are
/// shown verbatim so a user can give an app author the exact phase and diagnostic code.
struct NativeModelConversionReportContent: View {
	let report: NativeModelConversionImportReport
	let isPreparingExport: Bool
	/// Whether a converted model is actually on disk to export right now.
	let canExport: Bool
	let onExport: () -> Void

	/// The temporary file `ShareLink` hands to Files/AirDrop/Messages. `nil` until it is written,
	/// and if the write fails the Share item stays out of the menu rather than pointing at nothing.
	@State private var logExportURL: URL?

	init(
		report: NativeModelConversionImportReport,
		isPreparingExport: Bool = false,
		canExport: Bool = false,
		onExport: @escaping () -> Void = {}
	) {
		self.report = report
		self.isPreparingExport = isPreparingExport
		self.canExport = canExport
		self.onExport = onExport
	}

	var body: some View {
		Group {
			List {
				statusSection
				diagnosticSection
				sourceBytesSection
				metricsSection
				eventsSection
			}
			.navigationTitle(L10n.Import.conversionLog)
			// Written once the log is on screen rather than on every menu open, so the Share item is
			// either present and backed by a file or absent.
			.task(id: report.sourcePackageFilename) {
				logExportURL = NativeModelConversionReporting.exportedLogFile(for: report)
			}
			.toolbar { reportToolbar }
		}
	}

	private var statusSection: some View {
		Section(L10n.Import.conversionLogStatus) {
			// The identity of the model that failed — the whole reason this report is worth
			// sending (AIA-0778). Without it a support mail says which *phase* failed and
			// nothing about *what* failed, so it cannot tell anyone which models the app does
			// not yet support. A filename is not a path: the report's path-free promise is
			// about never recording where in the user's documents a file lives.
			LabeledContent(L10n.Import.conversionLogSourceFile, value: report.sourcePackageFilename)
			LabeledContent(L10n.Import.conversionLogState, value: report.state.rawValue)
			LabeledContent(L10n.Import.conversionLogSourceVersion, value: report.nativeConverterPackageVersion)
			LabeledContent(
				L10n.Import.conversionLogRevision,
				value: String(report.nativeConverterConversionRevision)
			)
		}
	}

	@ViewBuilder
	private var diagnosticSection: some View {
		if let diagnostic = report.diagnostic {
			Section(L10n.Import.conversionLogDiagnostic) {
				LabeledContent(L10n.Import.conversionLogCode, value: diagnostic.code)
				LabeledContent(L10n.Import.conversionLogPhase, value: diagnostic.phase.rawValue)
				Text(diagnostic.message)
			}
		}
	}

	@ViewBuilder
	private var sourceBytesSection: some View {
		// The failure case: no metrics, but the input size was captured before the attempt,
		// and it is the one number that says how big the model we could not convert was.
		// Only when `metrics` is absent — otherwise the section below already shows it,
		// alongside the output figures a success also has.
		if report.metrics == nil, let sourceByteCount = report.sourceByteCount {
			Section(L10n.Import.conversionLogMetrics) {
				LabeledContent(
					L10n.Import.conversionLogInputBytes,
					value: formattedByteCount(sourceByteCount)
				)
			}
		}
	}

	@ViewBuilder
	private var metricsSection: some View {
		if let metrics = report.metrics {
			Section(L10n.Import.conversionLogMetrics) {
				LabeledContent(
					L10n.Import.conversionLogInputBytes,
					value: String(metrics.sourceFootprint.totalByteCount)
				)
				LabeledContent(
					L10n.Import.conversionLogOutputBytes,
					value: String(metrics.emission.outputModelByteCount)
				)
				LabeledContent(
					L10n.Import.conversionLogOperations,
					value: String(metrics.emission.operationCount)
				)
				if let memoryUsage = metrics.processMemoryUsage {
					LabeledContent(
						L10n.Import.conversionProcessMemory,
						value: formattedByteCount(memoryUsage.currentProcessFootprintByteCount)
					)
					LabeledContent(
						L10n.Import.conversionObservedPeakMemory,
						value: formattedByteCount(memoryUsage.peakObservedProcessFootprintByteCount)
					)
					LabeledContent(
						L10n.Import.conversionObservedPeakIncrease,
						value: formattedByteCount(memoryUsage.observedPeakIncreaseByteCount)
					)
				}
			}
		}
	}

	private var eventsSection: some View {
		Section(L10n.Import.conversionLogEvents) {
			ForEach(report.entries.reversed()) { entry in
				VStack(alignment: .leading, spacing: 4) {
					Text(entry.state.rawValue)
						.font(.headline)
					if let progress = entry.progress {
						Text(progressDescription(progress))
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					if let diagnostic = entry.diagnostic {
						Text("\(diagnostic.code): \(diagnostic.message)")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
					Text(entry.timestamp, style: .time)
						.font(.caption2)
						.foregroundStyle(.tertiary)
				}
			}
		}
	}

	@ToolbarContentBuilder
	private var reportToolbar: some ToolbarContent {
		ToolbarItem(placement: .topBarLeading) {
			// Available for every state — a failed conversion has no exportable model, but its
			// log (including the diagnostic) is exactly what a user needs to send for support.
			// Email reuses the app's support-mail path (with its mailto: fallback); Share is the
			// plain-text alternative when the user would rather not use mail.
			Menu {
				Button {
					Task { await emailReport() }
				} label: {
					Label(L10n.Support.sendEmail, systemImage: "envelope")
				}
				// A written file and no `preview:` — the exact shape of `SupportRequestView`'s
				// support-log row, which is the one share in this app proven to survive
				// *Save to Files* on macOS. See
				// ``NativeModelConversionReporting/exportedLogFile(for:)`` for what the
				// three departures from it each cost.
				if let logExportURL {
					ShareLink(item: logExportURL) {
						Label(L10n.Common.share, systemImage: "square.and.arrow.up")
					}
				}
			} label: {
				// Text, not a glyph (AIA-0778). Named for the job rather than the mechanism
				// was the first half; the second is that no icon says "report this failure"
				// on sight. A user looking for a way to report a failed conversion has to
				// read the word to know this is it, so the word is what the toolbar shows.
				Text(L10n.Import.reportConversion)
			}
		}
		// Passed in, not derived here: a memory refusal keeps its converted model precisely so
		// it can leave the device (AIA-0889), but the model can also have been cleaned up
		// already — and this view deliberately touches no model paths to find out.
		if canExport {
			ToolbarItem(placement: .topBarLeading) {
				if isPreparingExport {
					ProgressView()
				} else {
					Button {
						onExport()
					} label: {
						Label(L10n.Import.exportConvertedModel, systemImage: "archivebox")
					}
				}
			}
		}
	}

	/// Both the share sheet here and the failure alert send the identical text; see
	/// ``NativeModelConversionReporting``.
	private var logText: String {
		NativeModelConversionReporting.logText(for: report)
	}

	/// Sends the log through the app's shared support-mail path, falling back to the user's default
	/// mail app (mailto:) when no in-app composer is available — the same tiers as the settings bug
	/// report. The plain-text Share option remains for when mail is unavailable entirely.
	@MainActor
	private func emailReport() async {
		await NativeModelConversionReporting.email(report)
	}

	private func progressDescription(_ progress: NativeModelConversionProgress) -> String {
		NativeModelConversionReporting.progressDescription(progress)
	}

	private func formattedByteCount(_ byteCount: UInt64) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(clamping: byteCount), countStyle: .memory)
	}
}
