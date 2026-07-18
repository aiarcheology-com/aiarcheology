//
//  NativeModelConversionReportView.swift
//  AI Archeology
//
//  User-visible, app-owned presentation of a durable conversion report.
//

import SwiftUI
import NativeModelConverter

/// Presents a path-free support and recovery report written by the host app.
///
/// This view deliberately reads no model or user-document paths. The report's protocol values are
/// shown verbatim so a user can give an app author the exact phase and diagnostic code.
struct NativeModelConversionReportView: View {
	@Environment(\.dismiss) private var dismiss
	let report: NativeModelConversionImportReport
	let isPreparingExport: Bool
	let onExport: () -> Void

	init(
		report: NativeModelConversionImportReport,
		isPreparingExport: Bool = false,
		onExport: @escaping () -> Void = {}
	) {
		self.report = report
		self.isPreparingExport = isPreparingExport
		self.onExport = onExport
	}

	var body: some View {
		NavigationStack {
			List {
				Section(L10n.Import.conversionLogStatus) {
					LabeledContent(L10n.Import.conversionLogState, value: report.state.rawValue)
					LabeledContent(L10n.Import.conversionLogSourceVersion, value: report.nativeConverterPackageVersion)
					LabeledContent(
						L10n.Import.conversionLogRevision,
						value: String(report.nativeConverterConversionRevision)
					)
				}

				if let diagnostic = report.diagnostic {
					Section(L10n.Import.conversionLogDiagnostic) {
						LabeledContent(L10n.Import.conversionLogCode, value: diagnostic.code)
						LabeledContent(L10n.Import.conversionLogPhase, value: diagnostic.phase.rawValue)
						Text(diagnostic.message)
					}
				}

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
			.navigationTitle(L10n.Import.conversionLog)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					// Available for every state — a failed conversion has no exportable model, but its
					// log (including the diagnostic) is exactly what a user needs to share for support.
					ShareLink(item: logText, preview: SharePreview(L10n.Import.conversionLog))
				}
				if report.state == .registered {
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

	/// A plain-text rendering of the report for the share sheet. Like the on-screen report it is
	/// path-free: it contains only the report's own protocol values (state, converter identity,
	/// diagnostic, metrics, and the event log).
	private var logText: String {
		var lines = [
			"AI Archeology — Native Model Conversion Log",
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

	private func progressDescription(_ progress: NativeModelConversionProgress) -> String {
		var values = [progress.phase.rawValue]
		if progress.totalUnitCount > 0 {
			values.append("\(progress.completedUnitCount)/\(progress.totalUnitCount)")
		}
		if let operationName = progress.operationName {
			values.append(operationName)
		}
		return values.joined(separator: " · ")
	}

	private func formattedByteCount(_ byteCount: UInt64) -> String {
		ByteCountFormatter.string(fromByteCount: Int64(clamping: byteCount), countStyle: .memory)
	}
}
