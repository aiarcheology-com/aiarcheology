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
4. **Ordering.** Commands run one at a time. Each connection is answered in request order. Requests from different connections interleave in no guaranteed order.

`HeadlessServer` binds an ephemeral port. It writes `{host, port, token}` atomically, with mode `0600`, to the endpoint file, and removes the file on `stop()`. A killed app cannot remove its file, so a launcher must not treat the file as proof that the app is running. `HeadlessClient` reports a refused connection as `notRunning`: the app is not running, or was suspended. A connection that sends no valid hello within 10 seconds is closed.

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
- **`capture`** maps a variable to a pointer. Later steps use `${variable}`. A string that is exactly `${variable}` keeps the value's JSON type. `${env:NAME}` reads the runner's environment. Credentials belong there, never in a scenario file. In a `matches` pattern, a substituted value is matched literally, never as regex syntax.
- The **runner** launches the installations, runs the steps in order, stops at the first failure, always runs `teardown` (continuing past teardown failures), and terminates what it launched. The `ScenarioReport` lists every failed expectation and keeps the full response of a failed step.
- **`bestEffort`** (teardown only): `"bestEffort": true` turns the step's failure into a warning instead of a failed run. Use it for cleanup that must be attempted from wherever a failed run stopped, but has nothing to do after a successful one, such as signing out when the steps already did. It is never silent: the report lists it under `warnings`, its step carries `"bestEffort": true` in the report's JSON, and `headless.sh test` prints it as `warning:` on a green run too. The decoder and `validate()` both refuse it outside `teardown`, so it cannot weaken a step's assertions. An ordinary teardown step that fails still fails the run.
- **Compatibility within a version.** A new optional key, such as `bestEffort`, is additive within a schema version: every file that was valid stays valid and means the same. A change that alters the meaning of an existing file bumps `schemaVersion`.

## ML Browser's headless build

ML Browser builds without its UI when `AIA_APP_INTERFACE=headless` is passed to `xcodebuild`:

```sh
xcodebuild build -workspace ios/MLBrowser.xcworkspace -scheme MLBrowser -configuration Debug \
  -destination "generic/platform=iOS Simulator" -derivedDataPath .deriveddata-headless \
  AIA_APP_INTERFACE=headless
```

- **Same app.** `AppEntry` launches `MLBrowserHeadless` instead of `MLBrowser`. It keeps the same app delegate, bootstrap and `AppRuntime`, and the same composition root. Only the views are replaced: the one window shows a status line, and a `HeadlessServer` takes their place.
- **Real composition.** The headless build uses what a Debug build uses: Clerk's development instance, the development findings backend, ConfigCat's Test environment, and persistent storage. Each simulator device is one installation of the app.
- **Launch options.** Pass them as launch arguments. Each is echoed in the handshake `metadata` and in `context`.
  - `-mockSubscription subscribed|notSubscribed` is needed because `simctl launch` never applies the scheme's StoreKit configuration, so real StoreKit is always "not subscribed" there.
  - `-headlessFlag key=true|false` is repeatable and pins a feature flag over the live provider. A scenario pins every flag it asserts on, because the Test environment can change under it.
- **Endpoint.** The server publishes `Library/Application Support/Headless/endpoint.json` in the app's data container (`xcrun simctl get_app_container <device> com.aiarcheology.ios data`).
- **Never production.** Three independent locks keep headless automation away from production data:
  1. The build's validation phase refuses `headless` outside `Debug` with the `development` backend.
  2. The server refuses to start unless the backend is `development`, and the in-app backend switch is disabled.
  3. The handshake reports `backendEnvironment`, so a launcher can refuse anything else.
- **Screens.** Every screen is derived from `AppState`, using the pure deciders the gate views read (`RootGateDisplay`, `WelcomePresentation`, `TourStartDecision`, `AnalyticsChoiceDisplay`). Each action calls the method the UI calls.

  | Route | Shown when | Actions |
  |-|-|-|
  | `launching` | `AppState` is not ready | none |
  | `gate` | the paywall, the free-access hold, or a Welcome screen, which the headless build cannot drive yet | none; `state` shows the gate inputs |
  | `tour` | the onboarding tour is armed or running | `skip` |
  | `consent` | the analytics question is on screen, or held (`state.pending`) | `allow`, `deny` (none while pending) |
  | `home` | the app proper, menu closed | `open-drawer` → `drawer` |
  | `drawer` | the menu is open | `close` → `home`; `enable id=…` (returns once the model has loaded, fails with the load error); `disable id=…`; `open-account` → `account` (only while signed out or signed in with a validated account, as the drawer's footer offers it) |
  | `account` | the drawer's account footer was opened: the sign-in sheet while signed out, the account once signed in | `close` → `drawer`; signed out: `sign-in email=… code=…`; signed in: `sign-out`. Neither while auth is resolving or offline |

  `drawer` state lists the menu's own models, from the same fetch as the view: `{id, name, type, enabled, canEnable, loaded}`. `account` state is `{signedIn}`. The wait conditions are `ready`, `model-loaded id=…`, `signed-in`, and the built-in `route route=…`. `context.gate` reports the gate inputs with every response. `context.auth` reports `gate`, `usesRealAuth`, `signedIn` (a validated account) and `accountPresent` (Clerk itself still holds a user, so a sign-out can be proven to have ended the session). It never reports the email address or the account id.
- **Signing in.** `sign-in` goes through Clerk's own API against the development instance: an email-code sign-in, or a sign-up first when Clerk does not know the address, then the gate refresh the app's sign-in sheet runs (see [AUTH-SUBSCRIPTION.md](AUTH-SUBSCRIPTION.md#signing-in-without-the-ui-debug-only-aia-0974)). No auth mock is involved. The action returns once the app holds a validated account, then closes the account screen as the sheet does; the account's own analytics question may then take the screen. `sign-out` calls `AuthState.signOut()`, the paywall's call, and closes the account screen as Settings does. It fails with `actionFailed` if Clerk still holds the session afterwards: the app signs a user out locally even when Clerk's request fails, but automation must not treat that as a clean sign-out.
  - It refuses to run on mock auth (a Debug build without Clerk keys) with `actionFailed`, so a keyless build cannot pass a sign-in scenario without reaching Clerk. `context.auth.usesRealAuth` says which a run got.
  - It accepts only **Clerk test addresses** at the reserved domain, `<name>+clerk_test@example.com`, and refuses anything else with `invalidArgument` before any request. It also refuses to run unless the build points at the development backend. Clerk's test mode sends these no email and accepts the fixed code `424242` ([Clerk docs](https://clerk.com/docs/guides/development/testing/test-emails-and-phones)). A failure reports Clerk's error code only, never text that could echo the address.
  - **The automation account** is `aia-headless+clerk_test@example.com` with code `424242`, committed in `sign-in-sign-out.json`. Both are Clerk's documented test values, not credentials. The account is **permanent** and exists **on the development instance only**. It was created once through Clerk's sign-up, with the names Headless Automation and a discarded random password. Because the development publishable key ships in every Debug build and test mode accepts `424242` for any test address, anyone holding that key can sign in as this account. It must **never hold real data**.
  - **The sign-up branch is not soaked.** The account already exists, so every scenario run takes the sign-in branch. To re-verify sign-up: `headless.sh exec --state a perform sign-in email=<new-name>+clerk_test@example.com code=424242` on a signed-out installation, then delete that user through Clerk's API. Sign in to it with the email code (native Frontend API: create a sign-in with strategy `email_code`, attempt code `424242`), then `DELETE /v1/me` (the instance allows self-deletion). A new sign-in attempt must then return `form_identifier_not_found`.
  - **Sessions.** A successful run signs out, which removes its Clerk session. The `sign-in-sign-out` teardown signs out from wherever a failed run stopped, as `bestEffort` steps. On a green run two of them have nothing to do and print as warnings every time: `deny` (no question is pending) and `sign-out` (already signed out). Those two warnings, with `unknownAction`, are expected. Any other teardown warning means a cleanup did not happen. A run that dies while auth is still resolving, where no account action is offered, leaves one session on the automation account until Clerk's session lifetime expires it or someone revokes it: sign in to the account through the Frontend API, `GET /v1/me/sessions/active`, then `POST /v1/me/sessions/{id}/revoke` for each.
  - The headless build mounts no `ClerkSessionWatcher`, which is a view. A session revoked on the server during a run is noticed at the next foreground re-validation, not immediately.
- **Tooling.** `scripts/headless.sh` wraps `ProjectTool headless`:
  - `build`
  - `up --state a [--mock-subscription subscribed] [--flag key=true…]`
  - `exec --state a <command>`, for example `exec --state a perform enable id=…`
  - `down --state a` and `reset --state a`
  - `test [files…]`, which runs every `ios/HeadlessScenarios/*.json` by default

  It creates and uses only simulators named `aia-headless-<state>` and never touches any other device. It builds into `.deriveddata-headless`, so the app module `unittest.sh` reuses is not rebuilt. A scenario's first launch of an installation erases its device, making it a fresh install. A freshly erased device can refuse `simctl install` and `simctl launch` for a few seconds after it reports booted, so the tool retries each up to five times, two seconds apart, and prints every retry. `relaunch` keeps its data and does not reinstall. Reinstalling moves the app's data container, and preference writes the system has not yet flushed would be lost with the move. A relaunch quits the app the way a force-quit does, so a preference written in the moment before it can still be lost, as on a device.
- **Things a run cannot control:** remote `appMessages` can change during a run, and a live message may raise a notification-authorization alert on the device. Neither may be asserted. Choosing `allow` at analytics consent sends TelemetryDeck signals, which the SDK marks as test-mode in Debug.

## Compatibility

`Command`, `Expectation`, and the error-code set can grow. Adopters should not switch over them exhaustively without a `default`. New protocol fields are always optional. A change that an older peer would misread bumps `HeadlessProtocol.version`, and the handshake then rejects the mismatch.
