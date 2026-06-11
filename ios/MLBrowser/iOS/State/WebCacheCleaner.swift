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
    @MainActor static func clean() {
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

    /// Clears cookies, cache and other website data for one site only.
    ///
    /// `domain` is the registrable domain (e.g. "bayern.de") — WebKit's data records
    /// are keyed exactly that way (`displayName`), so subdomains are covered.
    @MainActor static func clean(domain: String) async {
        let store = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: dataTypes)
        let matching = records.filter { $0.displayName == domain }
        await store.removeData(ofTypes: dataTypes, for: matching)

        let cookieStorage = HTTPCookieStorage.shared
        cookieStorage.cookies?
            .filter { $0.domain == domain || $0.domain.hasSuffix("." + domain) || $0.domain == "." + domain }
            .forEach { cookieStorage.deleteCookie($0) }

        LoggingPolicy.info("Website data cleared for one domain (\(matching.count) records)", logger: .storage)
    }

}
