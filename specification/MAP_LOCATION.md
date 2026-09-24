# Map location: recording where a finding was made

When a finding is saved while browsing a map site, the app records **where it was** — the page's
real URL, and a coordinate when one can be obtained. This describes how that works and, more
usefully, *why it works that way*, so the next person changing it knows which parts are load-bearing.

Introduced by AIA-0817. Code lives in `ios/MLBrowser/iOS/Services/MapLocation/`.

## The one rule

**No hostnames in the shipped decision path.** There are on the order of 200 target mapping sites,
so any design whose coverage grows by hand-written domains is the wrong design — it would need a
commit per site and rot as each site changed. Every mechanism keys on a **mapping library**, an
**open standard**, or the **shape of a value**. One library adapter is a whole family of sites.

Hostnames may appear in tests, fixtures and this document. They must not appear in a branch that
decides what gets recorded.

The second rule follows from the first: **we never re-project between coordinate systems.** Either
the page's own library performs the conversion, or the coordinate is recorded verbatim, labelled
with the system it is in. Re-projecting a national grid by hand produces confident, plausible,
wrong places.

Stated precisely, because an absolute "no arithmetic" claim would be false: averaging two corners
of a geographic bounding box, and converting Cesium's radians to degrees, are arithmetic *within one
coordinate system*. Neither can put a point somewhere else the way a bad projection can. What is
forbidden is turning one system's numbers into another's.

## What gets recorded

Two fields on the finding, both editable by the user afterwards:

- **Page** — the URL. This is the must-have and it is *always* recorded; the worst case is the
  page's own address with no coordinate.
- **GPS** — free text, prefilled once when the sheet opens, carrying its provenance:

  ```
  leaflet: 47.94123, 18.709545          read from a live Leaflet map
  arcgis: 50.0755381, 14.4378005        read from a live ArcGIS view
  url: 47.941230, 18.709545             read from the URL, verbatim
  shown: 49.683500, 14.042100           copied from a readout on the page
  S-JTSK (EPSG:5514): -828738, -1031271 the map's own position, in its own system
  ```

  The tag comes **first** because the share card renders this on one line with tail truncation — a
  trailing marker is exactly the part that would disappear, leaving a projected pair looking like a
  latitude and longitude.

Nothing here needed a Core Data change: `Finding.page` and `Finding.gps_` already existed, and
`gps_` being free text is what lets the tag travel with the number.

## How a location is found

Four independent witnesses, tried in order of how much they actually know. They are not fallbacks —
where two agree, the agreement is recorded as corroboration.

### 1. The live map (`exact`)

A script injected at **document start, in every frame** records map instances as their libraries
construct them. At capture time a second script asks the best instance — the one with the largest
rendered area, so an inset minimap never wins — where it is looking, using that library's own API.

Instances are found four ways, because no single one is enough:

| Mechanism | Reaches |
|-|-|
| Global constructor traps (`L`, `ol`, `maplibregl`, `google`, `Cesium`, `Potree`, `deck`) | Libraries loaded by `<script>` |
| DOM component hooks (`arcgis-map`, `arcgis-scene`) | ArcGIS web components, whose `.view` is public API |
| `$arcgis.views` | Modern ESM ArcGIS, including app templates — the Esri `Collection` of live views |
| **`Function.prototype.bind` trap** | **ESM bundles with no global at all** |

Wrapping the **module loaders** (`require`/`define`) was tried and deliberately removed: it broke
real pages — americanamap.org threw on its first module and rendered no canvas — and no site tested
needed it, because `$arcgis.views` reaches the ArcGIS apps it was aimed at. The `bind` trap below is
the general form of the same idea and is not a loader.

The `bind` trap is the subtle one and the highest-value. A modern bundled map assigns no global and
leaves no property on any DOM node — measured on openlayers.org and maplibre.org, where the
container, the canvas and every ancestor have *zero* own properties. But every one of these
libraries binds methods to the map while constructing it, and **the bound receiver is the map**. It
is identified by duck-typing that receiver, not by trusting any name.

Also relevant: several libraries assign their global *empty* and populate it afterwards, so the
namespace is watched for the constructor appearing rather than read once.

### 2. The URL (`inferred`)

Standard parameter names and positional grammars that many unrelated sites share — `lat`/`lon`,
OpenStreetMap's `#map=Z/LAT/LON`, `@LAT,LON,Nz`, `?pos=`, `?ll=`, and fragments behind a router
path (`#/map?lat=…`). Coverage widens by adding a *name*, which is one line and helps every site
using it.

Two guards matter more than the grammars:

- **A CRS marker abandons the URL.** If it says `srs=EPSG:25832`, its numbers are metres. Range
  validation is not enough on its own: an EPSG:3857 view near the origin (`x=100&y=50`) sits inside
  ±180 and would otherwise be stored as 50°N 100°E.
- **Ambiguous axis order is refused.** `center=48.8,19.53` is longitude-first in OpenLayers and
  ArcGIS but latitude-first in Google; when both readings are valid, none is recorded.

### 3. A coordinate the page displays (`inferred`)

Many portals show a readout. Copying that string verbatim needs no library and no conversion —
whatever format and datum the site chose travels with it.

### 4. Page metadata (`inferred`)

`<link rel="canonical">`, `og:latitude`/`og:longitude` and `geo.position`. Weakest, because it often
describes what a page is *about* rather than where it is looking. (JSON-LD `GeoCoordinates` is *not*
read: it was described here before it was written, and treating a business address as a viewport is
exactly the failure this tier is most prone to.)

## Refreshing a frozen URL

Some apps never touch the address bar while you pan, so their URL keeps whatever view you arrived
with — every finding on such a site would record the same place. Those apps usually offer a "copy
link to this view" button, which proves the app *can* serialise its current view into that
parameter; it simply does not do so continuously.

So: **if the URL already carries viewport numbers, refresh them from the live map.** Same parameter,
same coordinate system, current values. Nothing invents a format — the app put the parameter there,
this only updates its contents. A URL with no viewport parameter is left untouched.

The ordering trap here is real and was shipped once: a live map reports `x, y`, but `ll=` and `pos=`
are latitude-first, so writing one convention into the other transposes the pair into a
valid-looking URL pointing somewhere else. The order is chosen by whichever arrangement lands nearer
the values already present — a comparison, never a conversion.

## Which URL, exactly

Neither obvious candidate is right. The address bar's URL is throttled and, during a load, shows the
**requested** address while the old page is still on screen. Raw KVO can hold a *provisional* URL for
a document that does not exist yet.

So the app tracks the URL of the **committed** document, advanced by the KVO stream only while no
navigation is in flight. That second half is what makes it follow a map pan: `pushState` and
`replaceState` fire KVO and never commit, and `WKNavigationDelegate` has no public same-document
callback — the only such method is private SPI and not App Store safe.

## Binding the location to the image

Introduced by AIA-0846. A finding is an image plus a page and, on a map, a coordinate, and those
come from different awaits: the snapshot, then the live-map probe. The page can commit another
document, reload the same URL, lose its web view, or rewrite its own URL in between. Reading the
URL before an await proves nothing about what the next await returns, and URL equality cannot see
a reload at all.

So every snapshot carries a **capture context** (`CaptureContext` in `BrowserState.swift`), read
synchronously on both sides of the snapshot:

| Part | Changes when |
|-|-|
| document revision | a navigation commits (including a same-URL reload, a redirect, a back/forward restore), a web view is attached or invalidated |
| recorded URL | `captureURL` moves — including a same-document `pushState`/`replaceState` |
| live URL | `webView.url` moves — which also sees a rewrite while `captureURL` is held during another load |
| iframe revision | a recorded map iframe navigates and is superseded |

The rules that use it:

- **A different document** (revision changed, or no web view): the finding keeps the image's own
  URL and no coordinate. The live page is never probed to describe another page's image.
- **Same document, moved on** since the image: the live viewport need not be the one in the
  pixels. A detected pick releases the frame so detection takes a current one; if the page has
  moved again by the next tap in the same Find session, the image's own URL is recorded with no
  coordinate. A centre pick simply takes a fresh snapshot.
- **Unchanged**: the live map is asked, and its answer is kept only if the context is still
  unchanged when it arrives; otherwise the URL-only floor applies.
- **A snapshot whose context changed while WebKit took it** still feeds detection — refusing it
  would leave the boxes blank for a timer period after every pan on a map that rewrites its URL
  while it glides — but it cannot become a finding as it is: same-document ones follow the "moved
  on" rule, unknown-document ones are always released.
- The manual capture takes its image **first** and resolves the location for that image's context.

Residuals, stated rather than implied: WebKit may still paint the old document briefly after a
commit, and there is no public first-paint signal; a map that moves its viewport by script, with no
URL or iframe change and no user interaction, is not observable (as before); a brand-new iframe that
appears after the snapshot is not tracked, and was not in the pixels either; and a rewrite made
while another document is loading, *before* the snapshot, records the held `captureURL` with the
same document's live coordinate — the existing "which URL" policy above.

## Failing without taking the page down

Introduced by AIA-0821. The parser injects a script into every page at document start, and during
AIA-0817's development that script broke real sites outright — americanamap.org, openlayers.org and
basemap.at rendered nothing at all, because it installed accessor properties on `window` for names
like `L` and `define`. Those causes are fixed. What follows is the part that does not depend on
their staying fixed.

**The principle: if the parser fails, it must fail so the page is still usable.** A finding with no
coordinate is a small loss. A page that will not render is the product not working.

### One arbiter, three ways to be disarmed

`MapParserArming` answers a single question — may the parser touch this page? — and everything
consults it: the script injection, and the probe that questions the live map at capture time. It
says no when any of these holds.

| Switch | Who reaches it | Scope |
|-|-|-|
| `DISABLE_URL_LOCATION_PARSER` launch argument | a developer, bisecting | the whole session |
| **Settings → Web content → Read map position from pages** | the user | until they turn it back on |
| the circuit breaker | nobody; it fires itself | one host, this session |

Before this, only the launch argument existed, and only `MapLocationProbe` honoured it — so the
developer switch worked and a user had nothing at all. The switch suppresses the two things that
*touch* a page. The page's own URL is still recorded and the URL tiers still run, because reading a
coordinate out of an address the app already holds cannot cost anyone the page.

There is deliberately **no remote kill switch**. AGENTS.md §Feature flags asks for one and AIA-0821
revisited the question with the evidence in hand; the decision was that this feature is essential to
the app, so the flag would be a switch nobody should ever throw. A bad release therefore still needs
an app update to disarm globally. That is the accepted cost.

### The breaker, and why it trips on so little

It adds no JavaScript. Both of its sensors already existed for AIA-0827:

- **the confirmed blank verdict** — `RenderedContentSummary.drewNothing`, measured after the
  document finished and then again two seconds later, counting elements that actually *rendered*
  rather than elements that exist;
- **the main frame's error count**, from the page-diagnostics script.

It trips only on the conjunction: a document that was **armed**, whose **main frame** threw at least
once, and which **rendered nothing**. Each term is load-bearing. Errors alone are ordinary — the
listener is capturing, so it counts failed sub-resource loads, and a healthy page with one 404 image
reports an error. Blankness alone is how every application shell starts, which is why the
measurement behind it looks twice. And a page that broke while the parser was switched off is not a
page we broke. Which frame spoke is taken from WebKit's own `frameInfo`, never from the message
body, which the page controls.

On a trip the host is disarmed for the session and the page is reloaded **once** — silently, because
the user's problem is that the page is blank, not that they want to be told about it. The reload is
guarded: only while the web view is still showing the measured host and is not mid-navigation, and
never through `reloadTapped`, which would replenish the AIA-0509 recovery budget on the false
premise that a person had just expressed intent. Accepted and deliberate: `reload()` re-submits a
form POST without asking, bounded to one reload per host per session.

### Where the switch takes effect, and the limit that comes with it

User scripts are chosen when a document is created, so the script list is rebuilt in
`decidePolicyFor` — the one callback guaranteed to run before a destination document exists — and
again in `didReceiveServerRedirectForProvisionalNavigation`, where `webView.url` is already the
redirect target, so the decision is made against the address the document will actually have.
WebKit does run a redirected request through the action-policy delegate again, so the redirect
handler is belt-and-braces rather than the only guard — being wrong in that direction costs one
redundant call, while being wrong in the other carries the registry into the very host the breaker
just disarmed.
`WKUserContentController` has no per-script removal, only a bulk one, so every arming change
rebuilds the whole list; the touch-detection and diagnostics scripts are re-added by the same
function, which is why a test asserts they survive.

A navigation policy describes one navigation, so the breaker is keyed on the **top-level document's
host**. A tripped host embedded as an iframe inside an untripped page still receives the script.
`WKUserScript` offers no per-frame URL policy — the script is chosen before any frame's document
exists — so this is a limit of the platform rather than an oversight.

**This is not a hole in the no-hostnames rule.** That rule governs what gets *recorded*: coverage
must never grow by authored domains. The tripped set is observed at runtime, never written down,
never shipped, and decides only whether to stop — the rule is "no **authored** hostnames".

### The known limit: a document restored from the page cache

Going back to a page WebKit kept in its page cache restores the document that already ran, rather
than creating a new one. Nothing native can observe what that document was originally served, so
the arming label adopted at commit describes what the controller holds now, which may not be what
that document ran with. Turn the switch off, navigate away, turn it on, go back: the restored page
is labelled armed while its document never received the registry, and the reverse is equally
possible.

Two consequences, both accepted. A false trip disarms a site that did not deserve it, costing a
coordinate and one reload; a missed trip leaves a site armed that should not be. And because the
error count is reset per document, a restored page whose diagnostic timers already fired supplies
no fresh report, so a blank verdict on it cannot pair with anything and cannot trip at all.

The bound on all of it is the once-per-host reload, and relaunching re-arms everything. Fixing it
properly would need a way to ask a restored document what it ran with, which WebKit does not offer.

### What still runs on every page, honestly

The blast radius at document start was audited rather than redesigned. The honest finding is that
the poll loop is the smaller risk: it reads a dozen `window` properties every 20 ms and *writes*
nothing. It is not literally inert — reading `window[name]` invokes any getter the page has defined
there, and a side effect of that getter survives our `try` — but it installs nothing and replaces
nothing. The larger residual risk is the two mutations that persist:

- **`traceConstructor` replaces `ns.Map` / `Viewer` / `Deck` with a `Proxy`** for the life of the
  page. This is the largest untested page mutation in the feature.
- **`hookArcGIS3` rewrites five prototype methods.**

By contrast the `bind` trap, which looks like the most invasive thing here, restores the original
`Function.prototype.bind` after four seconds or 4000 inspections — and only if ours is still the
installed value, so a page that replaced `bind` in the meantime keeps its own.

The regression net is `map_bundle_namespace.html`, which performs the operations a bundle performs
on every watched global — assign empty then populate, delete then re-assign, `defineProperty` with a
value, and the AMD probe — and renders a sentinel only if every one succeeded. Its test asserts none
of those globals was an **accessor** when the page started, because an accessor is what broke the
real sites and is the first thing a future change would reintroduce. The descriptors are captured
before the page redefines anything; read afterwards they would only prove the page had overwritten
whatever was there.

**What that fixture does not cover**, so nobody mistakes it for a whole safety net: it constructs
through the traced constructors after a delay, so it meets `traceConstructor`'s `Proxy`, but it does
not exercise the ArcGIS 3.x prototype wrappers or the `bind` trap, and it is one synthetic page
rather than the real bundles. The breaker exists precisely because a test cannot enumerate the ways
a real site differs.

## Trust and privacy

The page is untrusted input. It can lie, clobber the registry, or return nonsense, so every value is
re-validated in Swift and **no returned string is ever evaluated**. Scripts are static constants; no
page data, URL or user input is ever interpolated into JavaScript. The probe fails closed — a
finding with no coordinate is correct, one with a guess is not.

Nothing about a URL, a fragment, a coordinate or page content is ever logged **by the probe**.
Its diagnostics are library names, counts and booleans only.

The page-diagnostics path (AIA-0827) is the deliberate exception and always was: a blank-page
verdict, and now a breaker trip, records the site in the message and the address in the crash
service's context. Both exist to answer "which site broke, and can I reproduce it", which a log
without the site cannot answer at all.

## Extending coverage

In rough order of value per unit of work:

1. **A library adapter** — one entry in the constructor traps plus one call in the centre reader.
   Covers every site using that library.
2. **A parameter name** — one entry in the URL vocabulary.
3. **An EPSG code** — one entry in the CRS name table, so a projected coordinate reads as
   `LV95 (EPSG:2056): …` rather than a bare number.

Adding a hostname is never the answer. If a site seems to need one, the question to ask is what
*class* of site it belongs to.

## Known limits

- **A truly custom map** with no recognisable library, no global, no bound methods and no URL state
  yields the page URL and nothing else. Tile-request sniffing would reach these and is deliberately
  not implemented.
- **Content identifiers are not places.** `?webmap=<id>` and Experience Builder routes identify an
  app, not a viewport, and must never produce a coordinate.
- **The `bind` trap depends on a construction-time detail.** It is broad and has held on every
  bundle tested, but it is not a public API contract.

## Testing

Fixture tests run offline against local HTML in `ios/MLBrowserUnitTests/Fixtures/MapHarness/`, with
**real vendored Leaflet and OpenLayers** — the risky claims are about *their* behaviour, and a stub
only proves the code agrees with the assumption it was written from. Fixtures reproduce measured
behaviour: the ArcGIS ones start `ready: false` with no centre, because that is what a real view
does at capture time.

`MapProbeInstallationTests` asserts the scripts the **app** ships, read from the app's own factory.
This exists because the whole probe once shipped inert — installed only by its own tests, green and
doing nothing. Any test that builds its own configuration cannot notice that.

`MapLocationLiveSiteHarness` hits real sites and is **opt-in**, skipped unless `MAP_LIVE_TESTS=1`,
because a third-party redesign or outage must not turn the build red. It asserts a per-site
expectation rather than only printing a report.

```
TEST_RUNNER_MAP_LIVE_TESTS=1 xcodebuild test-without-building \
  -workspace ios/MLBrowser.xcworkspace -scheme MLBrowser \
  -destination 'platform=iOS Simulator,name=ship-ticket-runner' \
  -only-testing:MLBrowserUnitTests/MapLocationLiveSiteHarness
```

### Manual test reference

Save a finding on each and check the two fields. Expectations were established by loading these
pages in a real browser; a page may of course change.

**Live-map path — a coordinate must appear**

| Page | Expect |
|-|-|
| `https://www.freemap.sk/#map=15/47.941230/18.709545` | `leaflet:` coordinate; URL tracks panning |
| `https://www.openstreetmap.org/#map=15/47.94123/18.70954` | `leaflet:` coordinate |
| `https://caltopo.com/map.html#ll=38.97469,-100.06486&z=12` | `leaflet:` coordinate. Its hash **collapses** as you pan, so a value here proves the live map was read, not the URL |

**Projected and non-URL-writing apps**

| Page | Expect |
|-|-|
| `https://ags.cuzk.cz/av/?extent=-831002.32,-1032569.72,-826473.74,-1029973.39&zvd=dmr5g` | `S-JTSK (EPSG:5514): …`, and the Page URL's `extent=` numbers **changed** from what you arrived with |
| `https://ags.cuzk.gov.cz/geoprohlizec/` | Same shape where its URL carries a viewport |

**ESM bundles — these have no global and no DOM back-reference**

| Page | Expect |
|-|-|
| `https://openlayers.org/en/latest/examples/simple.html` | `Web Mercator (EPSG:3857): …` via the `bind` trap |
| `https://demotiles.maplibre.org/#1.5/0/0` | `maplibre:` coordinate — a real viewer rather than a docs page. Confirmed in the app |

**URL-only grammars — no live map needed**

| Page | Expect |
|-|-|
| `https://zbgis.skgeodesy.sk/mapka/en/teren?pos=48.800000,19.530000,12` | `url: 48.800000, 19.530000` |
| `https://maps.nls.uk/geo/explore/side-by-side/#zoom=12&lat=53.15163&lon=-3.87707` | `url: 53.15163, -3.87707` |
| `https://boydsmaps.com/#14.00/39.739879/-74.223193/us3depShade1/0.00/0.00` | `url: 39.739879, -74.223193` |

**Negative — GPS must stay EMPTY**

| Page | Why |
|-|-|
| Any ordinary article or photo page | An invented coordinate is far worse than none |

Note the distinction that is easy to get wrong: a **content identifier is not a place**, so
`?webmap=<id>` or an Experience Builder route must never yield a coordinate *from the URL*. But the
live map on such a page is a perfectly good source, and an `arcgis:` coordinate appearing there is
correct rather than a false positive. The negative rule belongs to the URL tier alone.

**The editable fields**

- Type nonsense into Page and save — the finding must survive, keeping the URL it had.
- Clear Page entirely and save — respected; the finding then has no page.
- Edit Page on a **saved** finding from the Findings list — the change must persist.
- Neither must ever lose the finding or its screenshot.
