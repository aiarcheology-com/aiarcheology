# App → User Messaging (AIA-0115)

How ML Browser delivers remote, targeted messages to users — informational notices and
interactive prompts — without an App Store release, and how an operator publishes, targets,
and retracts them from the ConfigCat dashboard.

Messages ride the **existing feature-flag config pipeline** (see
[`FEATUREFLAGS.md`](./FEATUREFLAGS.md)). There is no separate backend: the whole campaign is a
single JSON array served from one ConfigCat text setting. Client rules live in
[`ios/AGENTS.md`](./ios/AGENTS.md) §3; the on-device privacy invariant is §10.

Master switch: **`isAppMessagingEnabled`** (ConfigCat, live, compiled default `true`). Off ⇒
every message disappears on the next poll.

## Architecture

### Delivery channel

- One ConfigCat **text setting**, key `appMessages`, holding a **JSON array** of message
  objects. It is served from the same `Main Config` as the boolean flags and is carried on
  `FeatureFlagSnapshot.appMessagesJSON`. A message edit republishes the snapshot exactly like
  a flag flip — `appMessagesJSON` is part of the snapshot's `Equatable`.
- Freshness is the SDK's job: it auto-polls every **~10 minutes (600 s) while the app is in
  the foreground** and `FeatureFlagsState` republishes on change. A publish therefore reaches
  live foreground devices mid-session, with no relaunch. A suspended app does not poll — the
  10-minute bound is foreground-only (same caveat as flags).
- Absent/unfetched/offline ⇒ `appMessagesJSON == ""` ⇒ no messages. Compiled fallback shows
  nothing; the dashboard value is the only source.

### Client pipeline

```
appMessages JSON  (ConfigCat text setting, rides the flag snapshot)
   │  FeatureFlagSnapshot.appMessagesJSON
   ▼
isAppMessagingEnabled gate ──off──▶ clear everything
   │ on
AppMessage.decodeMessages   tolerant, element-wise decode
   │
active-window (activeFrom/expiresAt) + version (min/maxAppVersion) filter
   │
per-surface split ──▶ alert surfaces (login / paywall / inApp)   +   aboutApp board
   │                        │                                          │
   │              seen / replied / sign-in gates            informational only,
   │                        │                               NO seen-gating
   │                 activeFrom-asc queue
   ▼                        ▼
one-at-a-time TOP BANNER              passive About board (whole active window)
```

### Types and files

| Concern | Type | File |
|-|-|-|
| Payload schema + tolerant decode | `AppMessage` | `ios/MLBrowser/iOS/State/AppMessages/AppMessage.swift` |
| Visibility pipeline, seen/replied, persistence, retraction, tap buffer | `MessageCenterState` | `ios/MLBrowser/iOS/State/AppMessages/MessageCenterState.swift` |
| Which surface is mounted now | `MessageSurfaceResolver` | `ios/MLBrowser/iOS/State/AppMessages/MessageSurfaceResolver.swift` |
| Top-banner presentation | `AppMessageModifier` | `ios/MLBrowser/iOS/UI/AppMessages/AppMessageModifier.swift` |
| About board (passive) | `AppDescriptionView` | `ios/MLBrowser/iOS/UI/SettingsView/AppDescriptionView.swift` |
| Reply merge-patch (pure) | `MessageReplyPatchBuilder` | `ios/MLBrowser/iOS/Services/MessageReplyPatchBuilder.swift` |
| Reply Clerk adapter | `ClerkMessageReplyWriter` | `ios/MLBrowser/iOS/State/AppMessages/ClerkMessageReplyWriter.swift` |
| Reply outbox / retry | `MessageReplyCoordinator` | `ios/MLBrowser/iOS/State/AppMessages/MessageReplyCoordinator.swift` |
| ConfigCat targeting user | `TargetingCoordinator` | `ios/MLBrowser/iOS/State/AppMessages/TargetingCoordinator.swift` |
| Notification plan (pure) | `MessageNotificationPlanner` | `ios/MLBrowser/iOS/Services/MessageNotificationPlanner.swift` |
| Notification adapter | `UserNotificationScheduling` | `ios/MLBrowser/iOS/Services/UserNotificationScheduling.swift` |
| Notification reconciler | `MessageNotificationCoordinator` | `ios/MLBrowser/iOS/State/AppMessages/MessageNotificationCoordinator.swift` |
| Flag + setting keys | `FeatureFlagKey`, `RemoteSettingKey.appMessages` | `ios/MLBrowser/iOS/State/FeatureFlags.swift` |
| Tap handling + BG refresh | `BackgroundDownloadAppDelegate` | `ios/MLBrowser/iOS/UI/MLBrowser.swift` |

## Payload schema

Each array element is a message object. Decoding is **tolerant and element-wise**: a malformed
element is dropped without affecting the others; malformed JSON (or a top level that is not an
array) is a **no-op** (`[]`). Unknown keys are ignored.

Every character cap below is **also a byte cap of 4× that count** in UTF-8. A Swift `Character`
is an extended grapheme cluster and can carry unboundedly many scalars, so counting characters
alone would bound neither memory nor Markdown-parse cost. Ordinary text — including CJK and
emoji — never comes close: a Unicode scalar is at most 4 UTF-8 bytes. Only deliberately
degenerate clusters (long combining-mark or ZWJ runs) exceed it, and those drop the message.

| Field | Req. | Semantics |
|-|-|-|
| `id` | yes | Unique identity. Non-empty, **≤100 chars**. Duplicate `id`s: **first wins**. Drives seen/replied/notify identity — see the re-publish rule below. |
| `title` | yes | **≤200 chars**. |
| `body` | yes | **≤4000 chars**. Supports **inline Markdown** — `[label](https://…)` links, `**bold**`, `*italic*`; no block syntax (headings/lists render literally). Tapping a link opens the **system browser**. A body that fails to parse renders as its literal text. |
| `surfaces` | yes | Array of `login` / `paywall` / `inApp` / `aboutApp` / `settings`. Unknown values dropped; **empty ⇒ the message is dropped**. |
| `localized` | no | Per-language overrides `{ "cs": { "title": …, "body": … } }`. Missing language or field falls back to top-level `title`/`body`, **per field** — a `title`-only override leaves the body in the source language. **Carries the same caps as the fields it replaces** — an override is what actually renders, so it is not a way around them. See Localizing a message for which keys resolve. |
| `notify` | no | Default `false`. `true` schedules a local notification (see Notifications) — **only if the message targets an alert surface** (`login`/`paywall`/`inApp`). An `aboutApp`/`settings`-only message is never notified: nothing could present it when the notification is tapped. |
| `activeFrom` | no | ISO 8601 (fractional seconds optional). Not-yet-active before this instant. `nil` ⇒ already active. |
| `expiresAt` | no | ISO 8601. Expiry is **exclusive** (inactive at exactly `expiresAt`). `nil` ⇒ **never expires; runs until removed**. Mid-session expiry works — a presented banner is dismissed when its window closes. |
| `minAppVersion` / `maxAppVersion` | no | Inclusive dotted-numeric bounds (`"1.10" > "1.9"`). A bound with any non-numeric component **fails open** (is ignored). |
| `buttons` | no | Interactive prompt. **≤8** buttons; each `{ id, label }` with `label` **≤60 chars**, `id` non-empty, **≤60 chars**, and **unique within the message**. A message with any bad/duplicate/empty-id button is **dropped whole** (the button list won't silently truncate). A message with ≥1 button is *interactive*; with none it is *informational*. |
| `url` | no | Optional associated URL (reserved; parsed). |
| `style` | no | `"info"` / `"warning"` / `"success"` tints the banner card and its inline rows on the About and Settings screens (blue / orange / green wash, legible in light and dark mode). Unknown or absent ⇒ the default untinted look — never drops the message. |
| `revision` | no | Default `0`. **Bump it to signal edited content**: a revision change **re-notifies** (see Notifications). Editing text without bumping `revision` updates the banner/About copy but does not re-notify. |

### The re-publish rule (memorize this)

`id` is the memory key for "user has seen / replied to this". A user who saw or replied to id
`X` will not see id `X` again, even if you delete it and re-publish identical content under
the same id. **To re-run a campaign, use a NEW `id`.** `revision` is *not* an escape hatch for
this — it only controls re-notification, not seen/replied suppression.

Honest limits of the guarantee: "seen" is device-local (a fresh install or second device shows
an informational message again), and replies are retained server-side only for the **newest
20** per user — an interactive id whose reply was pruned *and* whose local mark is gone (new
install) can prompt again. In practice: do not reuse ids, ever.

## Surfaces

| Surface | Where | Rendering | Gating |
|-|-|-|-|
| `login` | Sign-in screen (pre-auth) | Top banner | **Display-only**: informational only. Interactive messages **never render here** (no signed-in user to attribute a reply to). |
| `paywall` | Subscription gate | Top banner | Full gates apply. |
| `inApp` | The app proper | Top banner, **one at a time**, `activeFrom`-ascending queue (nil sorts first; ties by `id`) | Full gates apply. |
| `aboutApp` | Settings → About board | Passive inline list, **whole active window at once** | **Informational only, exempt from seen-gating.** Interactive messages are filtered out; nothing is marked seen by viewing. Never owns the banner. |
| `settings` | Settings form, pinned above the first section | Passive inline list, **whole active window at once** | Identical to `aboutApp`: informational only, seen-exempt, never owns the banner. The section is absent entirely when nothing is live. |

The banner is attached once at the scene root, above the auth/subscription/analytics gates, so
it can appear over login and paywall too. `MessageSurfaceResolver` maps the mounted gate to the
one live surface (or `nil` on a loading/offline/consent screen, where no banner shows).

**Alert-surface gates** (banner surfaces `login`/`paywall`/`inApp`):

- Informational (no buttons): hidden once **seen**.
- Interactive (has buttons): requires **sign-in**; always hidden on `login`; hidden once
  **replied** (server ∪ local reply set).

## Targeting (operator view)

Targeting is evaluated **server-side, per user**, by ConfigCat, against the evaluation user the
app sets:

- **Identifier** = the Clerk user id (never logged).
- **Custom attributes**: `appVersion`, `platform` (always `"iOS"`), `locale`,
  `subscribed` (`"true"` / `"false"`).

Build rules in the dashboard on the `appMessages` setting (or a boolean flag that a campaign
keys off): **+IF** → *Target users* (attribute comparators) / *Target a segment* / *Add
prerequisite*; **+%** for a percentage rollout.

**Signed-out devices and the login screen are served the setting's "To unidentified" /
fallback value** — a targeted campaign never reaches them. Put pre-auth `login` content in the
unidentified value. On sign-in the app re-sets the evaluation user and re-fetches immediately,
so **retargeting is instant — no config change needed**. Sign-out clears the user and reverts
to unidentified. The last-set targeting context is persisted so a background refresh can
restore it without a live UI session; no persisted context ⇒ background evaluates untargeted
defaults only.

Residual window: an identity switch re-evaluates gates immediately, but the *content* still
comes from the last-fetched config until the forced refresh lands (typically a second or two;
longer offline). On a shared device, a message targeted at the previous user could render
briefly in that window. Only content already delivered to that physical device is involved.

## Replies

- Stored on the **user's own Clerk record** at `unsafeMetadata.messageReplies` as a map
  `{ "<messageID>": { "choice": "<buttonID>", "at": "<ISO8601>", "appVersion": "<x.y.z>" } }`.
- Written via Clerk `updateMetadata` (server-side deep merge-patch): sibling metadata and other
  reply entries survive every write; `JSON.null` removes exactly one key.
- **Duplicate guard = first reply wins across devices.** An id already present server-side is
  not rewritten. Genuinely concurrent first writes resolve last-writer-wins server-side.
- **Retention: newest 20** by reply time; older entries are written as explicit tombstones
  (`null`) so the server map is pruned, not just the client.
- An outbox persists unsent replies and retries; a write racing a sign-out is treated as a
  failure (not cleared), so nothing is silently lost.

**Reading replies (operator):** per user in the Clerk dashboard → *Users* → the user →
*Metadata* → **Unsafe**. Across users, export via the **Clerk Backend API** (`unsafeMetadata`
per user). Replies are **deleted with the Clerk account** — the single GDPR delete point.

> `unsafeMetadata` is **user-writable by definition**. Replies are product signal only. **Never
> gate anything security-relevant on a reply.**

## Notifications and limits

Opt-in `notify: true` schedules a **local** notification (no server push).

- **Provisional (quiet) authorization**: requested at most once per process, only while
  undetermined. Provisional auth **never prompts** and delivers **silently to Notification
  Center — no banner, no sound** — until the user promotes notifications in Settings. The app
  never shows a permission prompt at launch.
- **Fire date = `max(now, activeFrom)`**. A device first syncing *inside* an active window
  notifies **on sync**, not at the nominal `activeFrom`.
- **Re-notify on `revision` bump** (id → revision is remembered). New id or bumped revision
  re-notifies; an unchanged revision does not.
- **Cap: 16 scheduled** (deterministic priority: `activeFrom` asc, ties by `id`; far under
  iOS's 64-pending limit). Overflow ids are logged, not scheduled.
- **Retraction** cancels pending **and** removes delivered notifications — **on the next
  fetch**. A **suspended device can still fire an already-scheduled notification before it
  learns of the retraction**, so **retract well before `activeFrom`**.
- **Tap** opens the app onto the message (buffered until a surface is available). A **stale tap
  (id no longer visible) is a silent no-op.**
- **Background refresh**: `BGAppRefreshTask` id
  `com.aiarcheology.mlbrowser.messages.refresh`, requested ~every **4 h** as an *earliest*
  begin date — **opportunistic**; iOS decides actual timing, and the user can disable
  Background App Refresh entirely.

## Retraction runbook

1. Remove the element from the `appMessages` array **or** set a past `expiresAt`.
2. **SAVE & PUBLISH.**
3. **Foreground devices** react within one poll (~10 min), including dismissing a
   mid-presentation banner and clearing About-board rows.
4. **Backgrounded/closed apps** react on next launch or BG refresh.
5. For notifications specifically, see the suspended-device caveat above — retract well ahead
   of `activeFrom`.

## Operator runbook

**Environments (identical to flags):** a **Debug build reads the Test env; TestFlight and App
Store read Production.** A Production publish reaches real App Store users **and** TestFlight
testers — there is no tester-only value. Rehearse against a Debug build on Test first.

> **SAVE & PUBLISH is mandatory.** An unsaved edit serves nothing (learned live). The
> dashboard's Save/Publish is the commit.

**Publish a message**
1. Edit the **Test** env value of `appMessages`, SAVE & PUBLISH.
2. Verify in a **Debug** build (banner/About/notification as intended, within ~10 min).
3. Edit the **Production** value, SAVE & PUBLISH.

**Target** — build +IF / +% rules on the setting (or a gating flag); remember the unidentified
value serves signed-out devices and login.

**Retract** — see the retraction runbook.

**Re-run a campaign** — publish under a **new `id`** (a reused id will not re-display to users
who saw/replied).

**Read replies** — Clerk *Users* → *Metadata* → *Unsafe* (per user); Backend API (bulk).

**Kill switch** — set `isAppMessagingEnabled` **OFF** in the env: all messages gone on the next
poll. (Compiled default is `true` / fail-open — the dashboard value is the control.)

**Keep payloads lean.** The whole config downloads on every poll; there is no practical
dashboard size limit, but bandwidth and the free-tier budget matter.

### Copy-paste example

```json
[
  {
    "id": "welcome-2026-07",
    "title": "Welcome to ML Browser",
    "body": "Thanks for trying on-device model inference.",
    "surfaces": ["login", "aboutApp"],
    "notify": false,
    "revision": 0
  },
  {
    "id": "beta-feedback-2026-07",
    "title": "Enjoying the beta?",
    "body": "Tell us how it's going — or read **what's new** in the [release notes](https://example.com/notes).",
    "style": "info",
    "surfaces": ["inApp"],
    "buttons": [
      { "id": "yes", "label": "Yes" },
      { "id": "no", "label": "Not really" }
    ],
    "notify": true,
    "activeFrom": "2026-08-01T00:00:00Z",
    "expiresAt": "2026-09-01T00:00:00Z",
    "minAppVersion": "1.2.0",
    "revision": 1
  }
]
```

## Localizing a message

ConfigCat has no localization feature — it serves one string per setting. Localization is ours,
and it lives **inside the message**: you publish one payload carrying every translation, and each
device picks its own row. One publish serves a user in Shanghai and a user in Chicago.

```json
{
  "id": "maintenance-2026-08",
  "title": "Scheduled maintenance",
  "body": "Sync is unavailable Sunday 02:00–04:00 UTC.",
  "surfaces": ["inApp"],
  "localized": {
    "zh-Hans": { "title": "计划维护", "body": "周日 02:00–04:00 UTC 无法同步。" },
    "cs":      { "title": "Plánovaná údržba", "body": "Synchronizace nebude dostupná…" }
  }
}
```

The top-level `title`/`body` **are** the source-language (English) version and the fallback for
every language you did not translate. Nobody ever sees an empty message, and no targeting rule is
involved — so this works signed-out, which matters because the `login` surface has no evaluation
user at all.

**Which keys resolve.** The device's tag is narrowed most-specific-first (RFC 4647 lookup, plus
`language-region`), so `zh-Hant-HK` tries `zh-Hant-HK` → `zh-HK` → `zh-Hant` → `zh`. Both a broad
`"zh"` and a precise `"zh-Hant"` therefore work, and the app's three Chinese localizations
(`zh-Hans`, `zh-Hant`, `zh-HK`) are individually addressable. The app ships **17** languages:

`ar bn cs de en es fa fr he hi hu pl ru uk zh-Hans zh-Hant zh-HK`

**Keep payloads lean.** Every device downloads every translation on every poll. Translate into the
languages you actually support rather than all 17 defensively.

**Finer than language** — per-country copy for one language, say — is a ConfigCat targeting rule
on the `locale` custom attribute (the full identifier; see Targeting), serving a different
`appMessages` value. That costs a rule per locale per campaign and does not apply signed-out, so
reach for it only when the in-payload map genuinely cannot express what you need.

### Ready-made payloads

Two fixtures live in [`fixtures/app-messages/`](./fixtures/app-messages), both verified against
the real decoder (`AppMessage.decodeMessages`) rather than by inspection:

| File | Contents |
|-|-|
| [`showcase.json`](./fixtures/app-messages/showcase.json) | 10 messages, **all 10 decode**. One per surface plus a 3-button interactive prompt, an inline-Markdown demo, a scheduled `activeFrom`/`expiresAt` window, and a version-bounded message. Two cover localization: `localized-maintenance` (full `cs` override, `de` title only — watch the body stay English) and `localized-chinese-variants` (`zh-Hans` / `zh-Hant` / `zh-HK` keyed separately, each body naming the key that matched, so you can see which one resolved). Override copy is illustrative, not translator-reviewed. |
| [`decoder-rejects.json`](./fixtures/app-messages/decoder-rejects.json) | 9 deliberately-malformed elements; **7 drop**. Only `keeper` (first of a duplicate pair) and `notify-inline-only` survive — the latter decodes fine but is never notified, since no alert surface can present it. |

Paste either into the `appMessages` setting with `isAppMessagingEnabled` on. Three things that
otherwise waste an afternoon: **seen/replied marks persist per account**, so re-testing needs a
*new* `id` (the UI tests suffix every id with a per-run token for exactly this); only the
**queue head** renders on a banner surface, so dismiss to reveal the next; and `version-targeted`
is bounded at `maxAppVersion: "1.9.9"`, so it shows on the current 1.0.x build and disappears
once you raise `minAppVersion` past it.

## Testing and development

- **UI tests** inject the payload via `UITestLaunchConfiguration.appMessagesJSON`
  (`StaticFeatureFlagProvider`) — the app under test **never hits ConfigCat**. Unit-tested
  pieces (`AppMessage`, `MessageReplyPatchBuilder`, `MessageNotificationPlanner`) are pure and
  take `now`/`appVersion`/`languageCode` as inputs.
- **Debug OSLog** on the `.state` logger (`LoggingPolicy.debug`) traces decode counts, presents,
  dismissals, replies, targeting set/clear, notification sync, and dropped taps.
- **Seen/replied persistence is account-realm-scoped** in `UserDefaults`
  (`appMessages.<userID>.<...>`; `anon` when signed out), resolved at access time so A→B→A
  restores each realm without an explicit reset. Settings → Reset → *Restore Defaults* does
  **not** touch these keys (it resets `Settings`-managed values only) — seen/replied marks
  survive it; only removing the app clears them. Replied state is additionally
  server-authoritative on the Clerk record, so reinstalls never re-prompt an answered
  interactive message (within the newest-20 retention). The seen and locally-replied lists are
  **capped at 500 ids per realm**, oldest evicted first; an evicted id can only resurface if
  that message is still live 500 marks later. Two things remain unbounded by design: the
  notified-revision map (pruning it would re-notify still-live messages — a notification storm
  is the worse failure), and the realms themselves, which are never garbage-collected across
  accounts. Both are small (campaign-id strings) and bounded in practice by how many campaigns
  you publish and how many accounts sign in on one device.

## Privacy

- **No analytics events.** App messaging emits none — it would violate the ANALYTICS.md payload
  rules (no ids, no content), so the feature is deliberately unmeasured.
- Two things leave the device, both first-party and functional: the **reply** (written to the
  user's own Clerk record) and the **targeting evaluation user** sent to ConfigCat with every
  config fetch while signed in — the Clerk user id plus `appVersion`, `platform`, `locale`,
  and `subscribed`. That evaluation data is what makes per-user/segment rules work; ConfigCat
  processes it to select the served value.
- Notification content is composed **locally** from the already-delivered payload.
- The AGENTS.md §10 on-device invariant (snapshots/detection imagery) holds.

## Future work

- **Backend message/delivery protocol log** once the #349 Phase-1 backend exists (deferred at
  G1; replies already persist on Clerk, so no data is lost in the interim).
- **Remote push (Phase B)** for real-time delivery to closed apps — today's channel is
  ConfigCat polling plus opportunistic BG refresh.

## Related

- [`FEATUREFLAGS.md`](./FEATUREFLAGS.md) — the ConfigCat pipeline this rides on
- [`ANALYTICS.md`](./ANALYTICS.md) — why messaging sends no analytics
- [`ios/AGENTS.md`](./ios/AGENTS.md) §3 (architecture rules), §10 (privacy)
