//
//  NativeModelConverterVersion.swift
//  NativeModelConverter
//
//  Runtime-identifiable native converter release and emission revision.
//

/// Version identity written into every generated Core ML model and app conversion report.
///
/// `packageVersion` follows the Swift package's SemVer release tag. `conversionRevision` changes
/// whenever a release changes native graph lowering, Core ML serialization, or target metadata in a
/// way that can affect a converted artifact without necessarily changing the public Swift API.
/// Source/exporter identity is intentionally separate and comes from
/// ``NativeModelProducer/name`` and ``NativeModelProducer/version`` in the graph package.
public enum NativeModelConverterVersion {
	public static let packageVersion = "0.1.0"
	/// Revision 10 corrects the measured accelerator policy for the pinned ADAF Faster R-CNN graph.
	/// Revision 9 requested `.cpuAndGPU` on probe-model evidence; on the real detector the GPU path
	/// moves a box 9.6623 px, worse than the Neural Engine's 3.9135 px, so only `.cpuOnly` holds the
	/// 1 px device parity budget.
	public static let conversionRevision = 10
}
