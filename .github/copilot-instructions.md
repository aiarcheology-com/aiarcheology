# Copilot Development Instructions

This repository contains a **SwiftUI-based application** that hosts a `WKWebView` browser with AI-powered object detection and classification capabilities.  
It supports **iOS 16+**, **iPadOS 16+**, and **macOS 14+** (running as a *Mac app designed for iPad*).

I am the **sole developer** of this project.

---

## Code Standards

### Core Development Philosophy
- **Pragmatic over Dogmatic**: Choose practical solutions that work well in production
- **Progressive Enhancement**: Start simple, iterate based on real needs
- **Performance-Conscious**: Consider memory and CPU impact, especially for AI operations
- **User-First**: Every technical decision should improve user experience

### General Principles
- Write **modular**, **extensible**, and **maintainable** Swift code
- Favor **clarity and simplicity** over cleverness
- **Fail fast, recover gracefully** — detect problems early but handle them elegantly
- Follow **The Pragmatic Programmer** principles:
  - **DRY (Don't Repeat Yourself)** — extract common patterns
  - **Orthogonality** — minimize coupling between modules
  - **Tracer Bullets** — iterate with working code early
  - **Refactor mercilessly** when patterns emerge
  - **Keep code close to the domain language** — use intuitive naming

### Swift and SwiftUI Style
- Use **Swift concurrency (`async/await`, `TaskGroup`, `AsyncSequence`)** by default
- Leverage **actors** for thread-safe state management
- Follow **SwiftUI data flow best practices**:
  - Use `@StateObject` for view-owned objects
  - Prefer `@Observable` macro (iOS 17+) where available
  - Pass data via `@Environment` for cross-hierarchy dependencies
  - Use `@Binding` for two-way data flow between parent-child views
  - Maintain **single source of truth** — avoid data duplication
- Prefer **composition over inheritance**
- Keep **view structs focused** — extract complex logic into view models
- Apply **dependency injection** via initializers or environment
- Use **type inference** where it improves readability
- Leverage **property wrappers** to reduce boilerplate

### Testing Strategy
- Design with **testability first** — if it's hard to test, refactor
- Use **protocol-based abstractions** for external dependencies (Core Data, networking, file system)
- Follow **AAA pattern** (Arrange, Act, Assert) in tests
- Testing principles:
  - **Isolate dependencies** using protocols and mock implementations
  - **Test behavior, not implementation** — focus on public APIs
  - **Keep tests deterministic** — avoid time-dependent or random behaviors
  - **Use descriptive test names** following `test_<scenario>_<expectedOutcome>` pattern
  - **One assertion per test** when practical
- Structure test helpers and mocks under `/Tests` with parallel folder structure
- Aim for **70%+ code coverage** on business logic, less on UI

### Performance Guidelines
- **Profile before optimizing** — use Instruments to identify bottlenecks
- Cache expensive computations appropriately
- Use **lazy loading** for large data sets and images
- Implement **debouncing/throttling** for high-frequency events
- Consider memory footprint, especially with ML models

---

## Repository Structure

The iOS project is organized under `/iOS` with the following modules:

| Folder | Purpose | Key Responsibilities |
|---------|----------|---------------------|
| **Assets/** | Image and icon assets | App icons, intro wizard graphics, UI imagery |
| **Documents/** | Legal and app documents | Privacy policy, terms of service (`.html`) |
| **Gallery/** | Classification mode feature | Feature-flagged with `.gallery`, image classification UI |
| **Rendering/** | Snapshot generation | Image capture, view-to-image conversion, render pipelines |
| **Tools/** | Shared utilities | Global extensions, helpers, common algorithms |
| **Configuration/** | App configuration | Environment setup, feature flags, build configs |
| **Drivers/** | AI engine abstraction | Pluggable detection/classification drivers, model interfaces |
| **Persistence/** | Data layer | Core Data abstraction, CRUD operations, migration, history |
| **State/** | State management | `AppState`, `DeepState`, entity linking, driver lifecycle |
| **UI/** | Presentation layer | Adaptive layouts for iPhone/iPad/Mac, reusable components |

### UI Substructure

| Folder | Description | Guidelines |
|---------|-------------|------------|
| **Modifiers/** | SwiftUI view modifiers | Reusable styling, layout utilities, animation helpers |
| **Annotation/** | Content overlay system | Shape drawing, web content annotation, coordinate mapping |
| **Appearance/** | UIKit styling | `UIAppearance` proxy configuration for iOS-specific theming |
| **Screens/** | Screen factories | Mode-dependent screen creation (`.web`, `.gallery`) |
| **SettingsView/** | App settings | Preferences, privacy controls, history management |
| **Side Menu/** | Navigation drawer | Adaptive menu system, chip-triggered activation |
| **Downloader/** | Model management | ML model downloads, progress tracking, `DeepState` integration |

---

## Design and Architecture Guidelines

### 1. **Extensibility**
- Apply **Open/Closed Principle** — extend without modifying core
- Use **protocol-oriented programming** for pluggable components
- Leverage **enums with associated values** for flexible state representation
- Design APIs that accommodate future requirements
- Create **extension points** in strategic locations

### 2. **Modularity**
- **High cohesion, low coupling** — group related functionality
- Each module should have a **single, clear responsibility**
- Use **dependency inversion** — depend on abstractions, not concretions
- Limit file size to ~200 lines where practical
- Prefer **many small files** over few large ones

### 3. **Maintainability**
- **Explicit is better than implicit** — avoid hidden behavior
- Follow **Swift API Design Guidelines** consistently
- Document:
  - **Public APIs** with clear descriptions
  - **Complex algorithms** with implementation notes
  - **Non-obvious decisions** with rationale
- Use **semantic versioning** for major changes
- Keep **technical debt log** for known issues

### 4. **Error Handling**
- Use **typed errors** (`enum MyError: Error`) for domain-specific failures
- Implement **Result types** for async operations without throwing
- Provide **user-friendly error messages** with recovery suggestions
- Log errors with appropriate severity levels
- Never silently swallow errors — at minimum, log them
- Consider **retry mechanisms** for transient failures

### 5. **Platform Adaptivity**
- Centralize platform detection in `HostPlatform` enum
- Use conditional compilation sparingly:
  ```swift
  #if os(iOS)
  // iOS-specific code
  #elseif targetEnvironment(macCatalyst)
  // Mac Catalyst-specific code
  #endif
  ```
- Prefer **adaptive SwiftUI** over platform-specific code
- Test on all target platforms regularly
- Consider screen size classes for responsive design

### 6. **Data Flow Architecture**
- Follow **unidirectional data flow** where possible
- State changes should be **predictable and traceable**
- Use **Combine** or **AsyncSequence** for reactive patterns
- Implement **command pattern** for user actions
- Consider **event sourcing** for complex state management

---

### Commit Conventions
- **Atomic commits** — one logical change per commit
- **Conventional commit messages**:
  ```
  <type>(<scope>): <subject>
  
  <body>
  
  <footer>
  ```
  Types: F for `feat`, B for `bug`, D for `docs`, S for `style` of `syntax`, R for `refactor`, T for `test`, C for `chore`, D for `deletetion` or `removal`
- Reference issues/tickets when applicable
- Keep commit messages under 72 characters
- Commits should have as the prefix the issue ID in form [AIA-XXXX], or [AIA-XXXX, <X>] <X> where is a set from the Types above.
- Pull request shold have in the title a prefix in form [AIA-XXXX]

---

## Copilot Guidance

When suggesting code:

### Preferred Patterns
- **Modern SwiftUI** with latest APIs (iOS 17+ features when available)
- **Structured concurrency** over completion handlers
- **Property wrappers** for cross-cutting concerns
- **ViewBuilder** for composable UI components
- **Result builders** for DSL-style APIs

### Code Generation Rules
1. Generate **idiomatic Swift** emphasizing:
   - **Type safety** — leverage Swift's type system
   - **Null safety** — use optionals appropriately
   - **Memory safety** — prefer value types, avoid retain cycles
   
2. For new features:
   - Start with **protocol definition** for testability
   - Create **minimal viable implementation** first
   - Add **comprehensive error handling**
   - Include **basic unit tests** structure
   
3. Platform considerations:
   - Wrap platform-specific code in appropriate conditions
   - Prefer **SwiftUI-native** solutions
   - Avoid UIKit/AppKit unless absolutely necessary
   - Use **Swift-native APIs** over C/Objective-C bridges

### Anti-patterns to Avoid
- ❌ Massive view controllers/view models
- ❌ Synchronous network calls on main thread
- ❌ Force unwrapping without safety checks
- ❌ Stringly-typed APIs
- ❌ Global mutable state
- ❌ Tight coupling between layers
- ❌ Copy-paste programming

### AI/ML Specific Guidance
- Consider **model size and loading time**
- Implement **progressive model loading** where applicable
- Cache **inference results** when deterministic
- Provide **fallback behaviors** for model failures
- Monitor **memory usage** during inference

## Quality Checklist
Before merging PR code, ensure:
- [ ] Code compiles without warnings
- [ ] Unit tests pass
- [ ] No memory leaks (verified with Instruments)
- [ ] Documentation updated for public APIs
- [ ] Performance impact assessed for new features
- [ ] Error cases handled gracefully
- [ ] Accessibility features maintained
- [ ] Platform compatibility verified
