#!/usr/bin/env swift
//
// xcstrings-to-strings.swift
// Converts Apple String Catalog (.xcstrings) to classic .strings format
//
// Usage: ./xcstrings-to-strings.swift <input.xcstrings> <output.strings>
//

import Foundation

// MARK: - Models

struct StringCatalog: Codable {
    let sourceLanguage: String
    let strings: [String: StringEntry]
    let version: String?
}

struct StringEntry: Codable {
    let localizations: [String: Localization]?
    let extractionState: String?
    let comment: String?
}

struct Localization: Codable {
    let stringUnit: StringUnit?
    let variations: Variations?
}

struct StringUnit: Codable {
    let state: String?
    let value: String
}

struct Variations: Codable {
    let plural: [String: PluralVariation]?
    let device: [String: DeviceVariation]?
}

struct PluralVariation: Codable {
    let stringUnit: StringUnit?
}

struct DeviceVariation: Codable {
    let stringUnit: StringUnit?
}

// MARK: - Conversion

func escapeForStringsFile(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

func convert(inputPath: String, outputPath: String) throws {
    let inputURL = URL(fileURLWithPath: inputPath)
    let data = try Data(contentsOf: inputURL)
    let catalog = try JSONDecoder().decode(StringCatalog.self, from: data)

    var output = ""
    var count = 0
    let sourceLanguage = catalog.sourceLanguage

    for (key, entry) in catalog.strings.sorted(by: { $0.key < $1.key }) {
        // Skip auto-extracted entries (only include manually added ones)
        guard entry.extractionState == "manual" else {
            continue
        }

        guard let localizations = entry.localizations,
              let localization = localizations[sourceLanguage] else {
            // Fallback: use key as value
            output += "\"\(escapeForStringsFile(key))\" = \"\(escapeForStringsFile(key))\";\n"
            count += 1
            continue
        }

        // Handle simple strings
        if let stringUnit = localization.stringUnit {
            let value = stringUnit.value
            output += "\"\(escapeForStringsFile(key))\" = \"\(escapeForStringsFile(value))\";\n"
            count += 1
        }
        // Handle variations (plurals, device variants)
        else if let variations = localization.variations {
            // For plurals, use the "other" form as default
            if let plural = variations.plural,
               let other = plural["other"],
               let stringUnit = other.stringUnit {
                let value = stringUnit.value
                output += "\"\(escapeForStringsFile(key))\" = \"\(escapeForStringsFile(value))\";\n"
                count += 1
            }
            // For device variants, use "other" as default
            else if let device = variations.device,
                    let other = device["other"],
                    let stringUnit = other.stringUnit {
                let value = stringUnit.value
                output += "\"\(escapeForStringsFile(key))\" = \"\(escapeForStringsFile(value))\";\n"
                count += 1
            } else {
                // Fallback to key
                output += "\"\(escapeForStringsFile(key))\" = \"\(escapeForStringsFile(key))\";\n"
                count += 1
            }
        } else {
            // Fallback to key
            output += "\"\(escapeForStringsFile(key))\" = \"\(escapeForStringsFile(key))\";\n"
            count += 1
        }
    }

    let outputURL = URL(fileURLWithPath: outputPath)
    try output.write(to: outputURL, atomically: true, encoding: .utf8)

    fputs("Converted \(count) strings to \(outputPath)\n", stderr)
}

// MARK: - Main

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: \(CommandLine.arguments[0]) <input.xcstrings> <output.strings>\n", stderr)
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

do {
    try convert(inputPath: inputPath, outputPath: outputPath)
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
