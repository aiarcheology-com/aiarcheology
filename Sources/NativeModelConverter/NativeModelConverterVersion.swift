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
	/// Revision 11 removes the ADAF compute-unit metadata. CPU-only remains the explicit placement
	/// for strict parity measurements, while product loading uses its own per-model setting and
	/// Automatic defaults to Core ML `.all`.
	public static let conversionRevision = 11
}
