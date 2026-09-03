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

## Trust and privacy

The page is untrusted input. It can lie, clobber the registry, or return nonsense, so every value is
re-validated in Swift and **no returned string is ever evaluated**. Scripts are static constants; no
page data, URL or user input is ever interpolated into JavaScript. The probe fails closed — a
finding with no coordinate is correct, one with a guess is not.

Nothing about a URL, a fragment, a coordinate or page content is ever logged. Diagnostics are
library names, counts and booleans only.

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
