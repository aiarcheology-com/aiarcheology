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
  "installations": { "a": { "launch": { "flags": { "isPaymentsEnabled": false } } } },
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
  - `-headlessFlag key=true|false` is repeatable and pins a feature flag over the live provider (below).
  - `-headlessStagedImage <name>` is repeatable and names an image the launcher staged (below). Only the name is passed, never a host path, and `launchOptions.stagedImages` echoes it.
  - `-mockSubscription subscribed|notSubscribed` replaces StoreKit with the mock. It is for manual `up` only, and **no committed scenario may use it**: `HeadlessScenarioPolicyTests` in the ProjectTool tests fails if one does.
    - Why it still exists: without it the headless build runs real StoreKit (AIA-0976). Under `simctl launch`, with no scheme StoreKit configuration, StoreKit reaches the sandbox, loads the real product and reads as not subscribed. A *subscribed* install would need a real sandbox purchase, which automation must not make, and there is no supported way to apply a `.storekit` file to a `simctl`-launched app. The mock is the only way to look at a subscribed install headlessly.
    - How to remove it: when a subscribed state can be reached without a purchase, for example through a supported StoreKit test configuration for launched apps.
- **Flag pins (AIA-0976).** Every scenario pins the four **entry flags**, which decide how a fresh install gets into the app. Everything else follows ConfigCat's Test environment unless a scenario is about it. `HeadlessScenarioPolicyTests` fails a scenario that leaves an entry flag unpinned.
  - `isPaymentsEnabled`: launch-captured. A fresh install has no mirrored value, so its first launch captures whatever the snapshot holds at that moment (the compiled default `false`, or the fetched Test value), and its relaunch captures the mirrored Test value. Unpinned, one scenario could meet the introduction on its first launch and the paywall or a free-access window after `relaunch`.
  - `isFreeAccessPeriodEnabled`: launch-captured, with the same first-launch race. It decides between the free-access Welcome screen and the wall.
  - `isAnalyticsEnabled`: live, not captured. A Test-environment change mid-soak removes the consent question from every scenario at once.
  - `isCrossDeviceAnalyticsIdentityEnabled` (`false`, except `sign-in-sign-out`): with it on, the consent question waits for Clerk's session check, so `deny` right after `skip` races Clerk. Only `sign-in-sign-out` pins it on, because it asserts the account's own question.
  - Evidence for the race: on 2026-09-27 an unpinned fresh install on `aia-headless-b` reported `isPaymentsSurfaceEnabled: true, freeAccess: open`, the Test values, while the compiled default for payments is `false`. Which one a first launch captures depends on fetch timing.
  - A dedicated ConfigCat environment for automation would let the entry pins go. That needs a new environment and SDK key, so it is deferred to the owner.
- **Staged images (AIA-0975).** A scenario's `launch` block may list repository files under `"stage": ["ios/…/image.png", …]`, and `headless.sh up` takes `--image <path>` (repeatable) for the same thing.
  - The launcher accepts only a relative path that resolves inside the repository, with symlinks resolved on both sides and compared by path component. The file must be a regular `.png`, `.jpg` or `.jpeg`, and no two entries may share a name.
  - Before every launch it copies each file into `Library/Application Support/Headless/Staged/<name>` in the app's data container.
  - Nothing is downloaded at run time. The picture stands in for the page snapshot the web screen detects on; browsing stays out of scope.
  - The scenarios use `ios/MLBrowserUnitTests/Fixtures/terrain_iphone.png`, an existing unit-test fixture from AIA-0306 whose source is not recorded. It is a grayscale terrain hillshade with no people, text or personal data. It is staged into local simulators and uploaded only to the development backend, so it adds no new distribution.
- **No crash reporting (a named substitution).** `headless.sh build` passes `SENTRY_DSN=` to `xcodebuild`, so the headless build has an empty DSN and the app leaves Sentry off, as it does in any build without the secret. The handshake reports `crashReporting: false`, and the launcher refuses to drive a build that reports anything else. A build made another way, or before this change, fails with a request to rebuild.
  - Why: Sentry's "Github Alert" rule has no environment filter, so the first error-level event from any environment, development included, opens a GitHub issue. Scenarios provoke failures on purpose, and a flaky soak would file issues.
  - How to remove it: delete the `SENTRY_DSN=` argument in `HeadlessWorkspace.build()` once that rule ignores the `development` environment.
- **Endpoint.** The server publishes `Library/Application Support/Headless/endpoint.json` in the app's data container (`xcrun simctl get_app_container <device> com.aiarcheology.ios data`).
- **Never production.** Three independent locks keep headless automation away from production data:
  1. The build's validation phase refuses `headless` outside `Debug` with the `development` backend.
  2. The server refuses to start unless the backend is `development`, and the in-app backend switch is disabled.
  3. The handshake reports `backendEnvironment`, so a launcher can refuse anything else.
- **Real by default (AIA-0976).** A fresh install enters the way a new user does: real StoreKit, the real Keychain free-access anchor, the free-access Welcome screen, the tour, then the consent question.
  - **The Keychain anchor.** The headless build uses `KeychainFreeAccessAnchorService`, as a user's install does. A throwaway probe build (never committed) read and wrote the production anchor item at launch on `aia-headless-a`, iOS 27.0 simulator, Xcode 27.2 beta:

    | Step | Anchor at the next launch |
    |-|-|
    | Relaunch | present |
    | Uninstall, reinstall | present: it survives app deletion |
    | `simctl erase` | absent: the device's keychain database is deleted |
    | `simctl keychain <udid> reset` on the booted device | absent |

    So erase alone makes a fresh install fresh on 27.0. The launcher also runs `simctl keychain <udid> reset` after booting a fresh install, as a guard for a runtime that might keep it.
  - **Gaps, not substitutions.** The headless build does not render the paywall or Welcome views, so it does not do what only they do:
    - It loads no products (`loadProducts()` runs from `WelcomeView` and `PaywallView`), so no scenario depends on the sandbox network.
    - It sends no `paywall.shown`. `welcome.shown` is still sent, from `FreeAccessState.markPromptShown()`.
    - It does not re-check the entitlement on foreground, which `SubscriptionGateView` does on `willEnterForeground`. A headless run never goes to the background between commands, and a `relaunch` is a cold launch that checks it.
- **Screens.** Every screen is derived from `AppState`. The root gate's part comes from `SubscriptionGateCoordinator`, the object `SubscriptionGateView` itself runs on: the headless build owns one, as it has one window, and runs its Debug-only `reconcile()` on each render once `AppState` is ready, which does what the view's `onChange` handlers would. The analytics gate's part comes from `AnalyticsChoiceDisplay`. Each action calls the method the UI calls.

  | Route | Shown when | Actions |
  |-|-|-|
  | `launching` | `AppState` is not ready | none |
  | `gate` | the hold while the free-access window is still being read | none; `state` shows the gate inputs |
  | `paywall` | the wall, or the wall over the app after access ran out mid-session | none: purchasing needs a real App Store purchase, and restoring would raise the App Store sign-in. `state` is `{isSubscribed, expired}` |
  | `welcome` | the root gate raised a Welcome screen: the free-access offer, or the payments-off introduction | `continue`, with no declared destination: the response's `route` is the tour when one is owed, otherwise the consent question or `home`. `state` is `{offer: freeAccess, days}` or `{offer: introduction}` |
  | `tour` | the onboarding tour is armed or running | `skip` |
  | `consent` | the analytics question is on screen, or held (`state.pending`) | `allow`, `deny` (none while pending) |
  | `home` | the app proper, menu closed | `open-drawer` → `drawer` |
  | `drawer` | the menu is open | `close` → `home`; `enable id=…` (returns once the model has loaded, fails with the load error); `disable id=…`; `open-account` → `account` (only while signed out or signed in with a validated account, as the drawer's footer offers it) |
  | `account` | the drawer's account footer was opened: the sign-in sheet while signed out, the account once signed in | `close` → `drawer`; signed out: `sign-in email=… code=…`; signed in: `sign-out`, and, as Settings offers them, `set-backup enabled=…` (the back-up switch; only with a Worker) and `remove-all-findings` (Reset → Remove Findings). None of the account actions while auth is resolving or offline |
  | `findings` | the drawer's Findings row was opened | `close` → `drawer`; `refresh` (pull to refresh); `synchronize` (the Synchronize button, signed in); `delete id=…` |
  | `save-finding` | a detection was picked: the save sheet over the web screen | `save title=… [label=…]`; `cancel` → `home` |
  | `backup-consent` | the back-up question is pending and nothing covers it: the root overlay, which sits below every sheet and waits behind the analytics question | `accept`, `decline` |

  `home` also offers `detect-image image=<staged name>` when the launch staged an image, and `pick detection=<index>` → `save-finding` while a detection pass is held. `drawer` also offers `open-findings` → `findings`.

  `drawer` state lists the menu's own models, from the same fetch as the view: `{id, name, type, enabled, canEnable, loaded}`. `account` state is `{signedIn}`, plus `backUpEnabled` while signed in with a Worker. The wait conditions are `ready`, `model-loaded id=…`, `signed-in`, `backed-up id=…`, `finding-present id=…`, `finding-absent id=…`, and the built-in `route route=…`. `context.gate` reports the gate inputs with every response, including the root gate's `display` (`content`, `wall`, `wallOverContent`, `hold`) and the raised `welcome` (`freeAccess`, `introduction` or null). `context.analytics.enabled` reports whether analytics is actually on: the user's answer under the live flag. `context.auth` reports `gate`, `usesRealAuth`, `signedIn` (a validated account) and `accountPresent` (Clerk itself still holds a user, so a sign-out can be proven to have ended the session). It never reports the email address or the account id.
- **Signing in.** `sign-in` goes through Clerk's own API against the development instance: an email-code sign-in, or a sign-up first when Clerk does not know the address, then the gate refresh the app's sign-in sheet runs (see [AUTH-SUBSCRIPTION.md](AUTH-SUBSCRIPTION.md#signing-in-without-the-ui-debug-only-aia-0974)). No auth mock is involved. The action returns once the app holds a validated account, then closes the account screen as the sheet does; the account's own analytics question may then take the screen. `sign-out` calls `AuthState.signOut()`, the paywall's call, and closes the account screen as Settings does. It fails with `actionFailed` if Clerk still holds the session afterwards: the app signs a user out locally even when Clerk's request fails, but automation must not treat that as a clean sign-out.
  - It refuses to run on mock auth (a Debug build without Clerk keys) with `actionFailed`, so a keyless build cannot pass a sign-in scenario without reaching Clerk. `context.auth.usesRealAuth` says which a run got.
  - It accepts only **Clerk test addresses** at the reserved domain, `<name>+clerk_test@example.com`, and refuses anything else with `invalidArgument` before any request. It also refuses to run unless the build points at the development backend. Clerk's test mode sends these no email and accepts the fixed code `424242` ([Clerk docs](https://clerk.com/docs/guides/development/testing/test-emails-and-phones)). A failure reports Clerk's error code only, never text that could echo the address.
  - **The automation account** is `aia-headless+clerk_test@example.com` with code `424242`, committed in `sign-in-sign-out.json`. Both are Clerk's documented test values, not credentials. The account is **permanent** and exists **on the development instance only**. It was created once through Clerk's sign-up, with the names Headless Automation and a discarded random password. Because the development publishable key ships in every Debug build and test mode accepts `424242` for any test address, anyone holding that key can sign in as this account. It must **never hold real data**.
  - **The sign-up branch is not soaked.** The account already exists, so every scenario run takes the sign-in branch. To re-verify sign-up: `headless.sh exec --state a perform sign-in email=<new-name>+clerk_test@example.com code=424242` on a signed-out installation, then delete that user through Clerk's API. Sign in to it with the email code (native Frontend API: create a sign-in with strategy `email_code`, attempt code `424242`), then `DELETE /v1/me` (the instance allows self-deletion). A new sign-in attempt must then return `form_identifier_not_found`.
  - **Sessions.** A successful run signs out, which removes its Clerk session. The `sign-in-sign-out` teardown signs out from wherever a failed run stopped, as `bestEffort` steps. On a green run two of them have nothing to do and print as warnings every time: `deny` (no question is pending) and `sign-out` (already signed out). Those two warnings, with `unknownAction`, are expected. Any other teardown warning means a cleanup did not happen. A run that dies while auth is still resolving, where no account action is offered, leaves one session on the automation account until Clerk's session lifetime expires it or someone revokes it: sign in to the account through the Frontend API, `GET /v1/me/sessions/active`, then `POST /v1/me/sessions/{id}/revoke` for each.
  - The headless build mounts no `ClerkSessionWatcher`, which is a view. A session revoked on the server during a run is noticed at the next foreground re-validation, not immediately.
- **Finding, saving, backing up (AIA-0975).** Only the picture is staged. Detection, persistence, upload and sync run the app's real code against the development findings Worker.
  - **Detecting.** `detect-image` runs `DeepDrivers.detect(on:tiling:)` with the enabled models and the app's tiling setting, then `DetectionPresentation.filteredFrame`: the two calls the web screen's detection coordinator makes. This happens in `StagedImageCapture`, a Debug-only State object; Harmonize keeps UIKit out of the adapter.
    - The result is `{detections:[{index, label, confidence}]}`, flattened in driver order, then observation order. It carries no boxes, image data or paths.
    - Vision output can vary with the compute unit, so scenarios assert at least one detection (`exists /result/detections/0/label`), never a count or a box.
  - **Saving.** `pick` builds the `FindingCapture` the web screen builds for a tapped detection, with no page URL. `save` calls `FindingRepository.save(capture:cropRect:metadata:)`, the save sheet's own call, with the author taken from the account's display name when the sheet opens (at `pick`), as the web screen seeds the sheet.
    - `save` returns `{id}` (the finding's `entityId`, the id every installation shares) once the sync cycle the save triggered has finished.
  - **The findings screen** lists the Findings sheet's own fetch: all ready findings, newest first. That includes received findings; the UI opens on its Mine tab.
    - Each finding is `{id, title, backup, hasImage}`, where `backup` is `backedUp`, `owed`, `keptOnDevice` or `none` (no ledger opinion, for example signed out).
    - The state also has `usage` (`{used, limit}` or null), `pendingUploadCount` and `parkedCount`.
    - Opening it does what the sheet's `onAppear` does: the orphan sweep, then a sync cycle, awaited.
  - **Every action that starts a sync returns once that cycle has finished:** `save`, `delete`, `refresh`, `synchronize`, `set-backup`, `accept` and `decline`.
    - `synchronize` returns `{outcome: succeeded|offline|quotaFull|failed}` from the button's own outcome line. It fails with `actionFailed` when no synchronize ran.
    - `remove-all-findings` returns after the local removal, as Settings does. Its tombstones go out on the next cycle.
  - **The back-up question** is raised in the middle of the cycle that sign-in sets off. Reach it with `wait route=backup-consent`, never by expecting the route in the `sign-in` response.
    - A sheet's `close`/`cancel` declares `backup-consent` as its destination when the question is pending, because that is where closing the sheet lands.
  - **Deviations from the app, by design:**
    - The headless build saves the **whole staged image**. The save sheet's crop editor frames the image from its on-screen viewport, which does not exist here, so `save` passes the unit rect through the sheet's own crop code.
    - **WebScreen is unchanged.** Its detection pick already lives outside the view (`FindingCapture.detection(at:…)`, `detectionAlignedWithCentre`). The rest of its capture path (snapshot provenance, location resolution) is browser-bound and out of scope.
    - After a save, the sheet also records the tour step and a review-prompt moment, and may offer sign-in. `save` does none of these: they are UI bookkeeping, not persistence.
    - The analytics question outranks a sheet in the route order (#974). No modelled flow reaches that combination, because the question only appears after the sign-in sheet has closed. A unit test pins the order.
  - **The second automation account** is `aia-headless-other+clerk_test@example.com` with code `424242`, for `foreign-findings-stay-local`. It is Clerk test values again, development instance only, and never holds real data. It was created once through the app's own sign-up branch (`headless.sh exec … perform sign-in` on a signed-out installation), so no soak run takes sign-up.
  - **Server data.** The development Worker (`aia-findings-staging.vladimir-slavik.workers.dev`) is shared by both accounts across every run. Its R2 storage counts against the same free allowance as production. So:
    - **Known-empty start.** After its first sign-in, each scenario checks through a successful `synchronize` that the account holds exactly what the scenario expects: no live rows, or only the finding it is about to consent to.
    - **Teardown owns the cleanup.** It uses ordinary steps, so a green run is a clean run. The installation that created rows runs `synchronize`, `remove-all-findings`, then `synchronize` again, which must report `succeeded` with no rows. The account that owns the rows sends the tombstones. In `foreign-findings-stay-local`, whoever is signed in last (Y) cleans first, so a regression that uploaded X's finding to Y leaves nothing behind. X then signs in to send the tombstones queued for X. Every installation that signed in signs out. Navigation steps are `bestEffort`, because a failed run can stop anywhere.
    - **Expected warnings.** Each green run prints the navigation steps that had nothing to do as `unknownAction` warnings: `deny`, `cancel`, `decline`. Any other warning, or a warning from a cleanup step, means a cleanup did not happen.
    - **Rows are the gate; bytes are advisory.** The Worker charges bytes before each R2 write and reclaims an uncommitted upload only after 24 hours. After a crash between an image upload and its metadata, `usage.used` can stay above zero with no row behind it. The teardown therefore checks `usage.used == 0` only as a `bestEffort` step.
    - **Recovering a dirty account.** If a scenario fails its known-empty check, sign in to that account with `headless.sh up`/`exec`, open findings, `synchronize`, `remove-all-findings` on the account screen, then `synchronize` again.
    - **Residual risks.**
      - A row imported by a concurrent pull between `remove-all-findings`' id snapshot and its batch delete loses its tombstone. The teardown's own `synchronize` does not see it, because the pull's cursor has already passed it. The next run's known-empty check on a fresh install catches it, and the recipe above clears it.
      - A pull halted by a retryable download error still reports `succeeded`.
    - **Tombstones stay.** Deleted rows remain in the index forever, and every fresh install pulls them, so the index grows slowly with each run.
      - To reset an account completely, sign in to it through Clerk's Frontend API and delete the user (`DELETE /v1/me`). The Worker's `user.deleted` webhook purges that Clerk user id's data.
      - Signing in with the same address afterwards creates a new user with an empty namespace. Scenarios name only the address.
    - **Never call the Worker's account-erase route (`DELETE /v1/me/data`) from automation or by hand.** It fences the Clerk user id permanently, and every later write for it fails with `410 account_deleting`.
- **Tooling.** `scripts/headless.sh` wraps `ProjectTool headless`:
  - `build`
  - `up --state a [--flag key=true…] [--image <repository path>…] [--mock-subscription subscribed]` (the mock is manual-only; see Launch options)
  - `exec --state a <command>`, for example `exec --state a perform enable id=…`
  - `down --state a` and `reset --state a`
  - `test [files…]`, which runs every `ios/HeadlessScenarios/*.json` by default

  It creates and uses only simulators named `aia-headless-<state>` and never touches any other device. It builds into `.deriveddata-headless`, so the app module `unittest.sh` reuses is not rebuilt. A scenario's first launch of an installation erases its device and resets its Keychain, making it a fresh install. A freshly erased device can refuse `simctl install` and `simctl launch` for a few seconds after it reports booted, so the tool retries each up to five times, two seconds apart, and prints every retry. `relaunch` keeps its data and does not reinstall. Reinstalling moves the app's data container, and preference writes the system has not yet flushed would be lost with the move. A relaunch quits the app the way a force-quit does, so a preference written in the moment before it can still be lost, as on a device.
- **Things a run cannot control:** remote `appMessages` can change during a run, and a live message may raise a notification-authorization alert on the device. Neither may be asserted.
- **Analytics signals from automation.** `consent-allow-persists` chooses `allow`, so every run of it sends the buffered funnel (`free_access.window_granted`, `welcome.shown`, `free_access.continue_tapped`, onboarding) to TelemetryDeck: anonymous, about ten runs per soak. The SDK marks every signal from a Debug build as test mode, and there is one app ID. This is kept on purpose, not substituted: blanking the app ID would let the scenario pass with analytics never activating. If the owner prefers no test signals at all, `TELEMETRYDECK_APP_ID=` in `HeadlessWorkspace.build()` is the alternative, and the scenario would then need a store-level check instead of `context.analytics.enabled`.
- **Error codes.** `error-contract` provokes, against the real app, `unknownAction`, `unreachable`, `unknownCondition`, `timeout`, `actionFailed` (`detect-image` on the committed text file `ios/HeadlessScenarios/Fixtures/not-an-image.png`) and `invalidArgument`, and checks that the app still works afterwards. `malformedRequest`, `unknownCommand`, `unauthorized` and `protocolMismatch` cannot be written in a scenario; the HeadlessKit tests cover them.
- **Soak notes.** A `relaunch` right after a preference write can lose it, as a force-quit can on a device. The sensitive step is in `onboarding-interrupted`: a relaunch right after `skip`, whose write is `TourState.markSeen()`. If it is lost, that installation shows `tour` where `consent` is expected.

## Compatibility

`Command`, `Expectation`, and the error-code set can grow. Adopters should not switch over them exhaustively without a `default`. New protocol fields are always optional. A change that an older peer would misread bumps `HeadlessProtocol.version`, and the handshake then rejects the mismatch.
