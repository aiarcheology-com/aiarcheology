# MLBrowser Logging Guide

## Overview

This application uses Apple's unified logging system (OSLog) for structured, privacy-conscious logging. All logs are automatically managed by the system, with rotation and retention handled automatically.

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

## Log Levels

Use appropriate log levels based on the significance and audience:

### `.debug`
- **Purpose**: Internal developer details, verbose diagnostics
- **Visible**: Development builds only
- **Example**: "Driver initialized with ID abc-123"

### `.info` / `.notice`
- **Purpose**: Noteworthy app state changes, user actions
- **Visible**: Development and production
- **Example**: "Core Data persistent store loaded successfully"

### `.warning`
- **Purpose**: Degraded behavior, retries, unexpected but recoverable conditions
- **Visible**: Development and production
- **Example**: "Multiple drivers found with same configuration ID"

### `.error`
- **Purpose**: Operation failures that can be recovered from
- **Visible**: Development and production
- **Example**: "Download failed: network connection unavailable"

### `.fault`
- **Purpose**: Fatal failures, invariant violations, imminent crashes
- **Visible**: Development and production
- **Example**: "Core Data persistent store failed to load"

### `.critical`
- **Purpose**: Critical failures, invariant violations, imminent crashes. Higher severity than .fault.
- **Visible**: Development and production
- **Example**: "Core Data persistent store failed to load"


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
    Logger.persistence.fault("Core Data failed to load: \(error.localizedDescription, privacy: .public)")
    LoggingPolicy.criticalFailure("Core Data persistent store failed to load")
}
```

### Recoverable Errors (Use structured logging)
Log errors but allow graceful degradation:
- Network timeouts
- Missing optional files
- User-correctable validation errors

```swift
catch {
    Logger.networking.error("Download failed: \(error.localizedDescription, privacy: .public)")
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

Logger.drivers.info("Loading model from \(path.lastPathComponent, privacy: .public)")
Logger.persistence.debug("Fetched \(count) entities")
Logger.networking.warning("Retry attempt \(attemptCount) of \(maxAttempts)")
```

### Error Logging with Context
```swift
do {
    try performOperation()
} catch {
    Logger.persistence.error("Operation failed: \(error.localizedDescription, privacy: .public)")
    DefaultCrashReporter.shared.recordError(error, context: [
        "operation": "save",
        "entityType": "DeepConfiguration"
    ])
}
```

### Lifecycle Logging
```swift
Logger.lifecycle.info("App entering background")
Logger.lifecycle.info("App returning to foreground")
```

### State Transitions
```swift
Logger.state.info("AppState initializing")
Logger.networking.info("Download state transition: \(oldState.rawValue) → \(newState.rawValue, privacy: .public)")
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

### Show info and above (hide debug/trace)
```lldb
platform shell /usr/bin/log stream --style compact --level info --predicate "subsystem == 'com.aiarcheology.ios'"
```

### Filter by subsystem
```lldb
platform shell /usr/bin/log stream --style compact --level debug --predicate "subsystem == 'com.aiarcheology.ios'"
```

### Filter by subsystem and category
```lldb
platform shell /usr/bin/log stream --style compact --level debug --predicate "subsystem == 'com.aiarcheology.ios' && category == 'Persistence'"
```

### Show only error and above (by messageType)
```lldb
platform shell /usr/bin/log stream --style compact --level debug --predicate "subsystem == 'com.aiarcheology.ios' AND messageType >= 'error'"
```

### Future Integration: Crash Reporting

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
