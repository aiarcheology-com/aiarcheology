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
		Logger.state.logInfo("All HTTP cookies deleted")

		WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
			Logger.state.logDebug("Deleting \(records.count) website data records")
			records.forEach { record in
				WKWebsiteDataStore.default().removeData(ofTypes: record.dataTypes, for: [record], completionHandler: {})
				Logger.state.logDebug("Website data record deleted: \(record.displayName)")
			}
		}
	}

}
