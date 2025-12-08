//
//  WebCacheCleaner.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 03.12.23.
//

import Foundation
import WebKit
import OSLog

final class WebCacheCleaner {

    @MainActor class func clean() {
		HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)
		LoggingPolicy.info("All HTTP cookies deleted", logger: .storage)

		WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
			LoggingPolicy.debug("Deleting \(records.count) website data records", logger: .storage)
			records.forEach { record in
				WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes, for: [record], completionHandler: {})
				LoggingPolicy.debug("Website data record deleted: \(record.displayName)", logger: .storage)
			}
		}
	}

}
