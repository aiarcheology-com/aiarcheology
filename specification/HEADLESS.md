# Headless apps: HeadlessKit, its protocol, and scenarios

HeadlessKit lets an agent or a test operate a real app **without its UI**. It sends commands and reads JSON back. The app runs its real models, persistence and backends. HeadlessKit replaces only the views, with a description of **screens** and the **user actions** each screen offers right now.

ML Browser is the first adopter; the app integration is tracked in AIA-0970 (#970). The package is app-agnostic: any SwiftUI app can adopt it.

## Products (root `Package.swift`)

| Product | Depends on | Purpose |
|-|-|-|
| `HeadlessKit` | Foundation | Screen/action model, `HeadlessSession`, wire types, `InProcessDriver` |
| `HeadlessKitTransport` | Network.framework | `HeadlessServer` (loopback JSON Lines) and `HeadlessClient` |
| `HeadlessScenario` | `HeadlessKit` | Declarative JSON scenarios and `ScenarioRunner` |

The package has no third-party dependencies. Tests: `swift test --filter HeadlessKitTests`, on macOS. They also run in the root package CI job.

## Adopting it in an app

1. Implement `HeadlessApplication` over your existing state objects. `currentScreen()` must **derive** the screen from app state on every call. A separate navigation stack would drift from the app.
2. Implement one `HeadlessScreen` per screen. `state()` returns redacted JSON. `actions()` returns only what a user could do here now; leave out anything the UI disables.
3. Each `HeadlessAction` handler calls **the same model methods the UI calls**. When a view does the work inline, move that work into the model first and have the view call it too. A handler returns once its effect has landed, by awaiting a readiness signal or `HeadlessWait.until`, never a fixed delay.
4. Declare transitions with `navigatesTo`. `goto <route>` only follows a transition the current screen offers, so a client cannot reach a screen a user could not. The session fails an action whose declared transition does not arrive.
5. Offer named `WaitCondition`s for effects that finish later, such as "model loaded". The built-in `route` condition always exists.
6. In a **debug-only** build, start `HeadlessServer(session:endpointFile:)`, and never in a release build. Loopback is reachable by every local process. The token keeps other processes out, but a listener has no place in a shipped app.

```swift
@MainActor final class MyHeadlessApp: HeadlessApplication {
	let model: AppModel
	init(model: AppModel) { self.model = model }
	func currentScreen() -> any HeadlessScreen { model.isSettingsShown ? SettingsScreen(model: model) : HomeScreen(model: model) }
}

@MainActor struct HomeScreen: HeadlessScreen {
	let model: AppModel
	var route: Route { "home" }
	func state() -> JSONValue { ["items": .array(model.items.map { ["id": .string($0.id)] })] }
	func actions() -> [HeadlessAction] {
		[HeadlessAction("open-settings", summary: "Open Settings.", navigatesTo: "settings") { [model] _ in
			model.showSettings()   // the method the Settings button calls
			return nil
		}]
	}
}
```

## Protocol v1

The protocol is JSON Lines over TCP on `127.0.0.1`: one JSON document per line, with keys sorted.

1. **Handshake.** The client sends `{"hello":{"protocolVersion":1,"token":"…"}}`. The server replies `{"hello":{"protocolVersion":1,"metadata":{…}}}`, or sends `{"error":{…}}` and closes on a wrong token (`unauthorized`) or version (`protocolMismatch`).
2. **Requests.** Requests are flat and carry an `id`:

   ```json
   {"id":"1","command":"state"}
   {"id":"2","command":"perform","action":"enable","arguments":{"id":"…"}}
   {"id":"3","command":"goto","route":"drawer"}
   {"id":"4","command":"wait","condition":"route","arguments":{"route":"home"},"timeout":30}
   ```

   The other commands are `help` and `actions`. Arguments are validated against the action's parameters before the handler runs. Unknown names and wrong types are rejected. Textual forms such as `"3"` and `"true"` are converted to the declared type.
3. **Responses.** Every response carries `id`, `ok`, `route`, `state`, `actions`, `context`, an optional `result`, and an optional `error` of the form `{code, message}`. App-level failures are responses, not dropped connections. Error codes: `malformedRequest`, `unknownCommand`, `unknownAction`, `unknownCondition`, `unreachable`, `invalidArgument`, `actionFailed`, `timeout`, `unauthorized`, `protocolMismatch`. Codes are an open set.
4. **Ordering.** Commands run one at a time in arrival order, across all connections.

`HeadlessServer` binds an ephemeral port. It writes `{host, port, token}` atomically, with mode `0600`, to the endpoint file, and removes the file on `stop()`. `HeadlessClient` reports a refused connection as `notRunning`: the app is not running or was suspended.

## Scenarios (schema v1)

A scenario is a JSON file. Decoding is strict: an unknown key anywhere is an error, so a typo cannot silently assert nothing.

```json
{
  "schemaVersion": 1,
  "name": "enable-a-model",
  "installations": { "a": { "launch": { "mockSubscription": "subscribed" } } },
  "steps": [
    { "on": "a", "wait": { "condition": "route", "arguments": { "route": "home" }, "timeout": 60 } },
    { "on": "a", "goto": "drawer", "capture": { "model": "/state/models/0/id" } },
    { "on": "a", "perform": { "action": "enable", "arguments": { "id": "${model}" } },
      "expect": [ { "equals": { "pointer": "/state/models/0/enabled", "value": true } } ] },
    { "on": "a", "relaunch": true, "expect": [ { "route": "home" } ] }
  ],
  "teardown": []
}
```

- **`installations`** are independent copies of the app, each with its own data. `launch` is opaque to the runner; the adopter's `InstallationLauncher` interprets it.
- A **step** does at most one of `goto`, `perform`, `wait` or `relaunch`. A step with none of them observes the current screen. `on` is required when there are several installations.
- **`expect`** accepts `route`, `equals`, `exists`, `absent`, `matches` (a regex against a string), and `error` (the command must fail with that code). Pointers address the response document: `/route`, `/state/…`, `/context/…`, `/result/…`, `/error/code`. A response carrying an error fails the step unless an `error` expectation names it.
- **`capture`** maps a variable to a pointer. Later steps use `${variable}`. A string that is exactly `${variable}` keeps the value's JSON type. `${env:NAME}` reads the runner's environment. Credentials belong there, never in a scenario file.
- The **runner** launches the installations, runs the steps in order, stops at the first failure, always runs `teardown` (continuing past teardown failures), and terminates what it launched. The `ScenarioReport` lists every failed expectation and keeps the full response of a failed step.
