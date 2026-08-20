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
	/// Revision 4 adds the two-stage detector operations (crop/resize, top-K, gather, non-maximum
	/// suppression and the elementwise primitives the box arithmetic composes from), the standalone
	/// ROI box head chunk named by an artifact manifest in the primary model's metadata, and the
	/// parity provenance every emission now records.
	public static let conversionRevision = 4
}
