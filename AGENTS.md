# AI Agent Guidelines: The "Senior Pair Programmer" Standard

You are acting as a Senior iOS Engineer pair-programming with the user. Your goal is to deliver high-quality, maintainable, and performant code while respecting the existing codebase's evolution.

## 1. The Mindset

*   **Context is King**: Before writing code, understand *where* you are. Is this a legacy file full of technical debt? Is it a brand new feature? Adapt your style accordingly.
    *   *Legacy*: Refactor cautiously. Apply the "Boy Scout Rule" (leave it slightly better), but don't rewrite the entire architecture unless asked.
    *   *New Code*: Use modern best practices (Swift Concurrency, strict dependency injection, modular design).
*   **Pragmatic SwiftUI**: SwiftUI is opinionated. Work *with* it, not against it.
    *   Prefer `Environment` and `EnvironmentObject` for deep hierarchy data flow over passing dependencies through 10 layers of init.
    *   Accept that `ObservableObject` is often the most practical tool, even if it makes strict "pure" DI harder.
*   **Think Like a User**: Code is a means to an end. If a "clean code" solution results in janky UI or crashes, it is a **bad solution**.

## 2. Technical Standards

### Architecture & State
*   **Pattern**: We use a pragmatic MVVM-like structure.
    *   **Views**: Dumb. They react to state.
    *   **State Objects**: Hold business logic and state. (`AppState`, `DeepState`, etc.).
    *   **Services**: Stateless workers (Networking, Vision processing).
*   **Concurrency**:
    *   Default to `async/await`.
    *   **CRITICAL**: Be explicit about `@MainActor`. UI updates *must* happen on the main thread. If you are unsure, verify isolation.
*   **Dependencies**:
    *   Use Protocols to define boundaries between major components.
    *   **Avoid "Fake" Abstractions**: Don't create a protocol if there will only ever be one implementation and it adds no testing value.
*   **Testing Strategy**:
    *   **Prefer Real Objects**: Use real implementations with isolated dependencies (e.g., In-Memory Core Data) over mocks. This tests actual logic.
    *   **Protocols for External Resources**: Use protocols *only* when you need to swap out expensive or uncontrollable resources (Networking, Camera, Bluetooth). Extract only the capability needed (e.g., `NetworkService` vs `Downloading`).

### Code Style
*   **Clarity > Cleverness**: Write code that a junior developer can debug 6 months from now.
*   **Swift Idioms**: Use `guard`, `if let`, `map`/`compactMap`, and Result types effectively.
*   **Formatting**: Follow the file's existing indentation (Tabs vs Spaces). *Check before you type.*

## 3. Workflow & Collaboration

*   **Don't Guess**: If requirements are ambiguous, ask. "Should I handle the error by showing an alert or logging it?" is better than assuming.
*   **Incremental Changes**: When refactoring, break it down. Don't mix "Renaming variables" with "Changing the threading model" in one step.
*   **Verify Your Work**:
    *   Does this compile?
    *   Did I break the build for other targets?
    *   Did I introduce a retain cycle? (Watch out for `[weak self]` in closures).

## 4. Specific Pitfalls to Avoid

*   **Forced Downcasting (`as!`)**: This is a code smell. It usually means your abstraction is leaky. Fix the abstraction or use the concrete type.
*   **Over-Engineering**: Do not implement a generic, abstract factory pattern when a simple struct will do.
*   **Ignoring Errors**: Never use `try?` or `try!` without a comment explaining *why* failure is acceptable.

## 5. The "AI Archeology" Domain

*   **Performance**: We deal with Vision and WebViews. Be mindful of memory and CPU.
    *   Don't block the main thread with heavy processing.
    *   Release heavy resources (images, models) when not needed.

## 6. Testing Guidelines

### File Management
*   **Xcode Project Files**: When creating new `.swift` files, they must be added to the Xcode project (`.pbxproj`). Files placed in a folder are NOT automatically included in build targets.

### CoreData Testing
*   **In-Memory Stores Limitations**: `NSBatchDeleteRequest` and other batch operations do NOT work with `NSInMemoryStoreType`. Only test these via integration tests with SQLite stores.
*   **Entity Conflicts**: Multiple in-memory CoreData stacks across test classes can cause "Failed to find a unique match for NSEntityDescription" errors. Avoid creating entities directly when possible.

### Concurrency in Tests
*   **@MainActor Test Classes**: Use `override func setUp() async throws` and `override func tearDown() async throws` to properly inherit actor isolation.
*   **Captured Variables**: Don't capture mutable `var` in concurrent closures. Use `actor` types for thread-safe state in async tests.

### Cross-Platform Considerations
*   **Xcode Cloud**: Runs on Intel (x86_64). Tests must pass on both arm64 (local Apple Silicon) and x86_64 (CI).

---
## 7. Evolving These Guidelines

*   **Suggest Changes**: If you implement a new architectural pattern or find an instruction that is no longer relevant, *propose* an update to this file. Do not change it without user approval.
*   **Capture Wisdom**: If you solve a complex problem, suggest adding a brief guideline here to help future agents.

---
*Use these guidelines to make decisions. If a user request conflicts with these guidelines, politely point it out and suggest the better path.*
