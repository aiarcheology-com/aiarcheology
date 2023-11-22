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

// https://stackoverflow.com/a/68532373
extension String {
	public enum DateFormatType {

			/// The ISO8601 formatted year "yyyy" i.e. 1997
		case isoYear

			/// The ISO8601 formatted year and month "yyyy-MM" i.e. 1997-07
		case isoYearMonth

			/// The ISO8601 formatted date "yyyy-MM-dd" i.e. 1997-07-16
		case isoDate

			/// The ISO8601 formatted date and time "yyyy-MM-dd'T'HH:mmZ" i.e. 1997-07-16T19:20+01:00
		case isoDateTime

			/// The ISO8601 formatted date, time and sec "yyyy-MM-dd'T'HH:mm:ssZ" i.e. 1997-07-16T19:20:30+01:00
		case isoDateTimeSec

			/// The ISO8601 formatted date, time and millisec "yyyy-MM-dd'T'HH:mm:ss.SSSZ" i.e. 1997-07-16T19:20:30.45+01:00
		case isoDateTimeMilliSec

			/// The dotNet formatted date "/Date(%d%d)/" i.e. "/Date(1268123281843)/"
		case dotNet

			/// The RSS formatted date "EEE, d MMM yyyy HH:mm:ss ZZZ" i.e. "Fri, 09 Sep 2011 15:26:08 +0200"
		case rss

			/// The Alternative RSS formatted date "d MMM yyyy HH:mm:ss ZZZ" i.e. "09 Sep 2011 15:26:08 +0200"
		case altRSS

			/// The http header formatted date "EEE, dd MM yyyy HH:mm:ss ZZZ" i.e. "Tue, 15 Nov 1994 12:45:26 GMT"
		case httpHeader

			/// A generic standard format date i.e. "EEE MMM dd HH:mm:ss Z yyyy"
		case standard

			/// A custom date format string
		case custom(String)

			/// The local formatted date and time "yyyy-MM-dd HH:mm:ss" i.e. 1997-07-16 19:20:00
		case localDateTimeSec

			/// The local formatted date  "yyyy-MM-dd" i.e. 1997-07-16
		case localDate

			/// The local formatted  time "hh:mm a" i.e. 07:20 am
		case localTimeWithNoon

			/// The local formatted date and time "yyyyMMddHHmmss" i.e. 19970716192000
		case localPhotoSave

		case birthDateFormatOne

		case birthDateFormatTwo

		case createMl

		case messageRTetriveFormat

		case emailTimePreview

		var stringFormat:String {
			switch self {
						//handle iso Time
				case .createMl: return "yyyy-MM-dd'T'HH:mm:ss.SSS"
				case .birthDateFormatOne: return "dd/MM/YYYY"
				case .birthDateFormatTwo: return "dd-MM-YYYY"
				case .isoYear: return "yyyy"
				case .isoYearMonth: return "yyyy-MM"
				case .isoDate: return "yyyy-MM-dd"
				case .isoDateTime: return "yyyy-MM-dd'T'HH:mmZ"
				case .isoDateTimeSec: return "yyyy-MM-dd'T'HH:mm:ssZ"
				case .isoDateTimeMilliSec: return "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
				case .dotNet: return "/Date(%d%f)/"
				case .rss: return "EEE, d MMM yyyy HH:mm:ss ZZZ"
				case .altRSS: return "d MMM yyyy HH:mm:ss ZZZ"
				case .httpHeader: return "EEE, dd MM yyyy HH:mm:ss ZZZ"
				case .standard: return "EEE MMM dd HH:mm:ss Z yyyy"
				case .custom(let customFormat): return customFormat

						//handle local Time
				case .localDateTimeSec: return "yyyy-MM-dd HH:mm:ss"
				case .localTimeWithNoon: return "hh:mm a"
				case .localDate: return "yyyy-MM-dd"
				case .localPhotoSave: return "yyyyMMddHHmmss"
				case .messageRTetriveFormat: return "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
				case .emailTimePreview: return "dd MMM yyyy, h:mm a"
			}
		}
	}

	func toDate(_ format: DateFormatType = .isoDate) -> Date?{
		let dateFormatter = DateFormatter()
		dateFormatter.dateFormat = format.stringFormat
		let date = dateFormatter.date(from: self)
		return date
	}
}
