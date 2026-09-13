# AI Archeology Logging Guide

## Overview

This application uses Apple's unified logging system (OSLog) for structured, privacy-conscious logging. All logs are automatically managed by the system, with rotation and retention handled automatically.

All log messages include ISO 8601 timestamps with millisecond precision, enabling chronological sorting and precise timing analysis.

## Viewing Logs

### Development
- **Xcode Console**: View logs in real-time during development
- **Console.app** (macOS): Filter logs by subsystem `com.aiarcheology.ios`
- **Command line**: `log stream --predicate 'subsystem == "com.aiarcheology.ios"'`

### Production
Logs are automatically compressed and managed by the unified logging system. They do not accumulate indefinitely on user devices.

## Logging Categories

The application organizes logs into logical categories:

| Category | Purpose | Example Use Cases |
|----------|---------|-------------------|
| **App** | Application-wide events | Initialization, global state changes |
| **Lifecycle** | App lifecycle events | Launch, background/foreground transitions |
| **Drivers** | AI engine operations | Model loading, detection, classification |
| **Rendering** | Rendering operations | Snapshot generation, image processing |
| **Configuration** | Configuration management | Demo models, settings changes |
| **Persistence** | Core Data operations | CRUD operations, migrations, errors |
| **State** | State management | AppState, DeepState operations |
| **Networking** | Network & downloads | Model downloads, network errors |
| **UI** | User interface events | User actions, view lifecycle |
| **Gallery** | Gallery module | Photo picker, file operations |

## Timestamps

All log messages automatically include ISO 8601 timestamps with millisecond precision using the new logging methods:

```
2025-10-20T13:46:05.233Z Fetched 7 DeepConfiguration entities
2025-10-20T13:46:05.285Z Creating driver of type detect for configuration ED1A28E4
2025-10-20T13:46:05.335Z Detector initialized with ID ED1A28E4-D59D-41CA-A723-5174BF2BDA70
```

### Usage

Use the new timestamped logging methods that automatically prepend timestamps:

```swift
// Use logDebug, logInfo, logWarning, logError, logFault instead of debug, info, etc.
Logger.drivers.logInfo("Model loaded successfully")
Logger.networking.logError("Download failed: connection unavailable")
Logger.persistence.logDebug("Fetched \(count) entities")
```

**Important:** Always use the `log*` methods (e.g., `logInfo`, `logDebug`) instead of the standard Logger methods (e.g., `info`, `debug`) to ensure timestamps are included.

### Configuration

Timestamps can be configured via `LoggingConfiguration`:

```swift
// Disable timestamps globally
LoggingConfiguration.timestampsEnabled = false

// Re-enable timestamps
LoggingConfiguration.timestampsEnabled = true

// Timestamps are enabled by default
```

### Benefits

- **Chronological sorting**: Log entries can be sorted lexicographically by timestamp
- **Precise timing**: Millisecond precision enables accurate performance analysis
- **Cross-correlation**: Correlate events across different log categories and sources
- **UTC timezone**: All timestamps use UTC (indicated by Z suffix) for consistency

### Performance

Timestamp generation is optimized with:
- Cached `DateFormatter` instance to avoid repeated initialization
- Only creates `Date()` when timestamps are enabled
- Minimal overhead: ~0.002ms per timestamp on average

## Log Levels

Use appropriate log levels based on the significance and audience:

### `.debug`
- **Purpose**: Internal developer details, verbose diagnostics
- **Visible**: OSLog in development builds only. **Retained in the support log in every build
  configuration** while the user keeps "Keep a detailed log" on in Settings (AIA-0602). The Sentry
  breadcrumb remains development-only — that gate exists for the breadcrumb quota, and applying it
  to the support attachment as well is what removed 87 debug call sites from every customer report.
- **Volume**: the support log is capped at five MiB and evicts oldest-first, so a hot-loop call site
  spends the window everyone else shares. Aggregate per-iteration detail into one entry rather than
  logging inside the loop; `Detector.detect` is the worked example.
- **Export**: since AIA-0643 the exported log is **sealed** — HPKE (X25519 + ChaCha20-Poly1305) to a
  public key shipped in `Info.plist`, opened with `ProjectTool support-log decrypt`. This does not
  relax anything above. Redaction still runs, because the seal protects the log in transit and from
  whoever the user forwards it to, not from us; every rule in this guide about what may be logged
  applies unchanged. It does mean the user can no longer read what they send, which is why the
  in-app copy and the privacy policy say so explicitly.
- **Example**: "2025-10-20T13:46:05.233Z Driver initialized with ID abc-123"
- **Usage**: `Logger.drivers.logDebug("Driver initialized with ID abc-123")`

### `.info` / `.notice`
- **Purpose**: Noteworthy app state changes, user actions
- **Visible**: Development and production
- **Example**: "2025-10-20T13:46:05.285Z Core Data persistent store loaded successfully"
- **Usage**: `Logger.persistence.logInfo("Core Data persistent store loaded successfully")`

### `.warning`
- **Purpose**: Degraded behavior, retries, unexpected but recoverable conditions
- **Visible**: Development and production
- **Example**: "2025-10-20T13:46:05.335Z Multiple drivers found with same configuration ID"
- **Usage**: `Logger.drivers.logWarning("Multiple drivers found with same configuration ID")`

### `.error`
- **Purpose**: Operation failures that can be recovered from
- **Visible**: Development and production
- **Example**: "2025-10-20T13:46:05.636Z Download failed: network connection unavailable"
- **Usage**: `Logger.networking.logError("Download failed: network connection unavailable")`

### `.fault`
- **Purpose**: Critical failures, invariant violations, imminent crashes
- **Visible**: Development and production
- **Example**: "2025-10-20T13:46:05.737Z Core Data persistent store failed to load"
- **Usage**: `Logger.persistence.logFault("Core Data persistent store failed to load")`

## Privacy Guidelines

### Automatic Privacy Protection
OSLog automatically redacts sensitive data in production builds. Use privacy annotations:

```swift
// Safe for production - redacted automatically
Logger.app.debug("User ID: \(userId, privacy: .private)")

// Visible in production - use for non-sensitive data only
Logger.app.info("Model loaded: \(modelName, privacy: .public)")

// Automatic in development, private in production
Logger.app.debug("Processing \(count) items")
```

### Never Log
- User credentials or authentication tokens
- Personal identifiable information (PII)
- File system paths containing user data
- API keys or secrets

### Safe to Log (with `.public`)
- Public model names
- File extensions
- Error types and codes
- State transition names

## Crash Policy

### Deterministic Crashes (Use `LoggingPolicy.criticalFailure()`)
Use for conditions that compromise app functionality or data integrity:
- Core Data store fails to load
- Required demo models missing from bundle
- Corrupted data that cannot be recovered

```swift
if let error = error {
    Logger.persistence.logFault("Core Data failed to load: \(error.localizedDescription)")
    LoggingPolicy.criticalFailure("Core Data persistent store failed to load")
}
```

**Note**: Use the `log*` methods (e.g., `logInfo`, `logDebug`, `logFault`) to automatically include timestamps.

### Recoverable Errors (Use structured logging)
Log errors but allow graceful degradation:
- Network timeouts
- Missing optional files
- User-correctable validation errors

```swift
catch {
    Logger.networking.logError("Download failed: \(error.localizedDescription)", isPrivate: false)
    DefaultCrashReporter.shared.recordError(error, context: ["operation": "download"])
    // Continue with fallback behavior
}
```

### Development-Only Assertions (Use `LoggingPolicy.assertionFailure()`)
Crashes in debug builds but logs in release:

```swift
guard configuration.entityId != nil else {
    LoggingPolicy.assertionFailure("Configuration entityId should not be nil")
    return
}
```

## Code Examples

### Basic Logging
```swift
import OSLog

// Use the new log* methods that automatically add timestamps
Logger.drivers.logInfo("Loading model from \(path.lastPathComponent)")
Logger.persistence.logDebug("Fetched \(count) entities")
Logger.networking.logWarning("Retry attempt \(attemptCount) of \(maxAttempts)")
```

### Error Logging with Context
```swift
do {
    try performOperation()
} catch {
    Logger.persistence.logError("Operation failed: \(error.localizedDescription)", isPrivate: false)
    DefaultCrashReporter.shared.recordError(error, context: [
        "operation": "save",
        "entityType": "DeepConfiguration"
    ])
}
```

### Lifecycle Logging
```swift
Logger.lifecycle.logInfo("App entering background")
Logger.lifecycle.logInfo("App returning to foreground")
```

### State Transitions
```swift
Logger.state.logInfo("AppState initializing")
Logger.networking.logInfo("Download state transition: \(oldState.rawValue) → \(newState.rawValue)")
```

## Filtering Logs

### By Subsystem
```bash
log show --predicate 'subsystem == "com.aiarcheology.ios"' --last 1h
```

### By Category
```bash
log show --predicate 'category == "Drivers"' --last 30m
```

### By Level
```bash
log show --predicate 'subsystem == "com.aiarcheology.ios" AND messageType >= "error"' --last 1h
```

### Streaming Live
```bash
log stream --predicate 'subsystem == "com.aiarcheology.ios"' --level debug
```

## Future Integration: Crash Reporting

The application includes a `CrashReporter` protocol for future integration with services like Crashlytics or Sentry:

```swift
protocol CrashReporter {
    func recordError(_ error: Error, context: [String: Any]?)
    func recordBreadcrumb(_ message: String, level: BreadcrumbLevel)
    func setCustomValue(_ value: String, forKey key: String)
}
```

Currently implemented with `DefaultCrashReporter` which logs to OSLog. To integrate a third-party service:

1. Create a class conforming to `CrashReporter`
2. Initialize your crash reporting SDK
3. Replace `DefaultCrashReporter.shared` usage with your implementation

## Best Practices

1. **Log at appropriate points**
   - Entry/exit of significant operations
   - State transitions
   - Error conditions
   - User-initiated actions

2. **Include context**
   - Operation being performed
   - Relevant IDs (UUIDs, entity IDs)
   - State before/after transitions

3. **Be concise**
   - Keep messages short and structured
   - Use consistent formatting
   - Avoid redundant information

4. **Think about privacy**
   - Default to `.private` for user data
   - Only use `.public` for truly public information
   - Redact sensitive data even in debug builds

5. **Test logging**
   - Verify logs appear in Console.app
   - Ensure privacy annotations work correctly
   - Check log levels are appropriate

## Troubleshooting

### Logs not appearing
- Check predicate syntax in Console.app
- Ensure subsystem matches exactly: `com.aiarcheology.ios`
- Verify log level filter includes the level you're looking for

### Too many logs
- Reduce `.debug` logging in hot paths
- Use `.debug` only for diagnostic information
- Consider using signposts for performance profiling instead

### Privacy redaction
- Development builds show all data by default
- Production builds automatically redact `.private` and default privacy
- Use `.public` only for non-sensitive data

## References

- [Apple OSLog Documentation](https://developer.apple.com/documentation/os/logging)
- [WWDC: Unified Logging](https://developer.apple.com/videos/play/wwdc2016/721/)
- [Console.app User Guide](https://support.apple.com/guide/console/welcome/mac)
