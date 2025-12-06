//
//  NSManagedObject+Extension.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 05.11.25.
//

import CoreData

extension NSManagedObject {
    var isPersisted: Bool { !objectID.isTemporaryID }
    var isNew: Bool { isInserted && !isPersisted }
}
