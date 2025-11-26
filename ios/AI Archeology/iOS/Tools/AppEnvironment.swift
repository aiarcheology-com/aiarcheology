//
//  AppEnvironment.swift
//  AI Archeology
//
//  Created by Vladimír Cortes Slavík on 26.11.25.
//

//  Usage / setup:
//
//  1. Debug configuration
//     Xcode already defines `DEBUG` for Debug builds.
//     `AppEnvironment.isDebugConfiguration` will be true only there.
//
//  2. Compile-time “is test build?” flags (optional but cheap & nice):
//     - Unit Test target → Build Settings → Other Swift Flags (Debug):
//       add: -D UNIT_TESTING
//     - UI Test target   → Build Settings → Other Swift Flags (Debug):
//       add: -D UI_TESTING
//
//     Then `isCompiledForUnitTests` / `isCompiledForUITests` are
//     compile-time constants the optimizer can completely strip.
//
//  3. Runtime UI-test vs unit-test detection:
//     In your UI test target’s setUp (or before launching):
//
//       let app = XCUIApplication()
//       app.launchEnvironment["UI_TESTING"] = "1"
//       app.launch()
//
//     Now, inside the app process, `isRunningUITests` / `isRunningUnitTests`
//     use the XCTest environment plus that `UI_TESTING` marker.
//

import Foundation

enum AppEnvironment {

    // MARK: - Compile-time configuration

    /// True only in Debug configuration (standard Xcode `DEBUG` flag).
    static let isDebugConfiguration: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// True when the code was compiled for the Unit Test target
    /// (requires `-D UNIT_TESTING` in that target’s Swift flags).
    static let isCompiledForUnitTests: Bool = {
        #if UNIT_TESTING
        return true
        #else
        return false
        #endif
    }()

    /// True when the code was compiled for the UI Test target
    /// (requires `-D UI_TESTING` in that target’s Swift flags).
    static let isCompiledForUITests: Bool = {
        #if UI_TESTING
        return true
        #else
        return false
        #endif
    }()

    // MARK: - Runtime detection

    /// True whenever *any* XCTest bundle is driving this process.
    static var isRunningUnderAnyTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// True when the app is currently being UI-tested.
    ///
    /// Requires the UI test target to set:
    ///     app.launchEnvironment["UI_TESTING"] = "1"
    static var isRunningUITests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil &&
               env["UI_TESTING"] == "1"
    }

    /// True when the app is currently being *unit*-tested (not UI-tested).
    ///
    /// Assumes:
    ///   - XCTest sets `XCTestConfigurationFilePath` for all test runs.
    ///   - UI tests additionally set `UI_TESTING = "1"` in the launch env.
    static var isRunningUnitTests: Bool {
        let env = ProcessInfo.processInfo.environment
        guard env["XCTestConfigurationFilePath"] != nil else { return false }
        return env["UI_TESTING"] == nil
    }
}
