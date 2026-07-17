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
				if report.state == .registered {
					ToolbarItem(placement: .topBarLeading) {
						if isPreparingExport {
							ProgressView()
						} else {
							Button {
								onExport()
							} label: {
								Label(L10n.Import.exportConvertedModel, systemImage: "square.and.arrow.up")
							}
						}
					}
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button(L10n.Common.done) {
						dismiss()
					}
				}
			}
		}
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
