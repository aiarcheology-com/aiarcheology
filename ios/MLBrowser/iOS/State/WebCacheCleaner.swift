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

    /// Clears all web browsing data including cookies, cache, and local storage.
    ///
    /// Uses WebKit's bulk removal API for better performance compared to
    /// per-record deletion.
    @MainActor class func clean() {
        // Clear HTTP cookies
        HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)
        LoggingPolicy.info("All HTTP cookies deleted", logger: .storage)

        // Clear all WebKit data using bulk removal API
        // This is more efficient than fetching records and deleting them one by one
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            LoggingPolicy.info("All website data cleared", logger: .storage)
        }
    }

}
