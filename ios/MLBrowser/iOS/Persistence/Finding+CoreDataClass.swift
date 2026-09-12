//
//  Finding+CoreDataClass.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 16.06.26.
//
//

import Foundation
import CoreData

@objc(Finding)
final public class Finding: NSManagedObject {
    /// Suppresses `willSave()`'s automatic `modifiedAt` stamp for this instance.
    ///
    /// Deliberately NOT persisted: it is a per-instance instruction, not finding data. Set it only
    /// on a write that carries an authoritative timestamp from elsewhere — restoring an archive
    /// (AIA-713 Phase 1) or applying a cloud copy (Phase 3) — where stamping "now" would hand the
    /// local device a false last-write-wins victory over the newer remote edit it just received.
    ///
    /// An explicit `modifiedAt = x` is NOT sufficient on its own: assigning a value equal to the
    /// already-committed one leaves `changedValues()` empty, so a later change to another attribute
    /// would let the automatic stamp fire anyway. This flag is the unambiguous signal.
    var preservesModifiedAt = false

    public override func awakeFromInsert() {
        super.awakeFromInsert()
        self.entityId = UUID()
        self.lifeCycleString = CoreDataManageableState.empty.rawValue
    }

    /// The single write-path choke point for `modifiedAt` (AIA-713).
    ///
    /// Core Data calls `willSave()` on every dirty object at save time — including objects mutated
    /// by code that has never heard of sync — which is why the stamp lives here rather than in
    /// `FindingRepository`. The `changedValues()` guard terminates Core Data's re-entrant
    /// willSave loop: assigning `modifiedAt` re-dirties the object, Core Data calls `willSave()`
    /// again, and on that pass the key IS present, so the second pass does nothing.
    ///
    /// Deleted objects are skipped so a pending delete is never re-dirtied back into the context.
    public override func willSave() {
        super.willSave()
        guard isDeleted == false, preservesModifiedAt == false else { return }
        if changedValues()["modifiedAt"] == nil {
            modifiedAt = Date()
        }
    }
}
