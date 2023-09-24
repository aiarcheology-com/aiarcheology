//
//  String+Extensions.swift
//  AI Archeology
//
//  Created by Vladimír Slavík on 24.09.23.
//

import Foundation

extension String {
    var withHTTPS: String {
        if self.hasPrefix("http://") || self.hasPrefix("https://") {
            return self // Return original string if it already has a prefix
        } else {
            return "https://\(self)" // Otherwise, prepend https:// to the string
        }
    }
}

enum SearchEngine {
    case google
    case bing

    func searchURL(for query: String) -> String {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        switch self {
        case .google:
            return "https://www.google.com/search?q=\(encodedQuery)"
        case .bing:
            return "https://www.bing.com/search?q=\(encodedQuery)"
        }
    }
}

extension String {
    func search(using engine: SearchEngine) -> String {
        if self.hasPrefix("http://") || self.hasPrefix("https://") {
            let quotedString = "\"\(self)\""
            return engine.searchURL(for: quotedString)
        } else {
            return engine.searchURL(for: self)
        }
    }
}

enum BrowserInpuType {
    case url
    case searchTerm
    case unusable
}

extension String {
    var browserInputType: BrowserInpuType {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)

        // If string is empty or just whitespace, return .unusable
        if trimmed.isEmpty {
            return .unusable
        }

        // If string contains spaces, consider it a search term
        if trimmed.contains(" ") {
            return .searchTerm
        }

        // Prepend scheme if it looks like a domain but lacks a scheme
        var modifiedInput = trimmed
        if !modifiedInput.hasPrefix("http://") && !modifiedInput.hasPrefix("https://") && modifiedInput.contains(".") {
            modifiedInput = "http://\(modifiedInput)"
        }

        if let url = URL(string: modifiedInput), let _ = url.host, url.scheme == "http" || url.scheme == "https" {
            // Regular Expression for URL validation
            let regex = try! NSRegularExpression(pattern: "((https?|ftp):\\/\\/)?(www\\.)?[\\w\\-._~:\\/?#\\[\\]@!$&'()*+,;=%]+", options: .caseInsensitive)
            if regex.firstMatch(in: modifiedInput, options: [], range: NSRange(location: 0, length: modifiedInput.count)) != nil {
                return .url
            }
        }

        return .searchTerm
    }
}
