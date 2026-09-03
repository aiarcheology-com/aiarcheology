//
//  MapProbeScript.swift
//  AI Archeology
//
//  The JavaScript half of AIA-0817: find the live map object a page is showing, and ask it — in its
//  own library's API — where it is looking.
//

import Foundation

/// The two static scripts the map-location probe injects.
///
/// ## Why JavaScript at all
/// Roughly 22% of the target catalogue (ArcGIS app templates) never writes its viewport to the
/// address bar, so no amount of URL parsing can locate it. The map object, however, always knows.
///
/// ## Why this is not per-site code
/// Every adapter below keys on a **mapping library**, never on a hostname. There are about six
/// libraries behind hundreds of sites, so one adapter is a whole family of sites — that is the only
/// unit of work whose cost is fixed while its coverage keeps growing.
///
/// ## Why we never do coordinate maths
/// Each adapter asks the library that owns the projection to do the conversion: OpenLayers'
/// `toLonLat` with its own registered projection, Esri's own `projection` module. A map in
/// EPSG:25832 is converted by the code that defines EPSG:25832. The one exception is Cesium's
/// radians-to-degrees, which is a unit change within one datum, not a reprojection.
///
/// ## Trust
/// Both scripts are **static string constants** — no page data, URL, or user input is ever
/// interpolated into JavaScript. Everything they return is untrusted: the page can lie, clobber the
/// registry, or return nonsense, so every number is re-validated in Swift and no returned string is
/// ever evaluated.
enum MapProbeScript {

	/// Installed at `.atDocumentStart` in every frame, before the page's own scripts run.
	///
	/// Records map instances *as they are constructed*, which is what reaches apps that keep no
	/// global reference to their own map — a `window` scan alone misses those entirely.
	///
	/// Known limit: a pure-ESM bundle that never touches `window` assigns no global and calls no
	/// AMD loader, so nothing here fires. Those pages fall through to the DOM and back-reference
	/// strategies in ``probe``, and then to URL inference.
	static let registry = #"""
	(function () {
	  // EVERYTHING below is wrapped. This script runs at document start on every page the user
	  // visits, so an exception escaping it could stop that page's own scripts from running — and
	  // reading a coordinate must never cost someone the page they were trying to look at. Each
	  // section is individually guarded as well; this is the backstop for the paths between them.
	  try {
	  if (window.__aiaMapRegistry) { return; }

	  var registry = { instances: [], libraries: [] };
	  try {
	    Object.defineProperty(window, '__aiaMapRegistry', {
	      value: registry, writable: false, enumerable: false, configurable: false
	    });
	  } catch (e) { return; }

	  // Bounded so a page that builds maps in a loop cannot grow this without limit.
	  function record(kind, instance) {
	    try {
	      if (!instance) { return; }
	      for (var i = 0; i < registry.instances.length; i++) {
	        if (registry.instances[i].instance === instance) {
	          // The bind trap fires during construction and can only say "a map"; a library-specific
	          // hook running afterwards knows which one. Let the specific answer replace the vague
	          // one, so the recorded provenance names the library rather than shrugging.
	          if (registry.instances[i].kind === 'unknown' && kind !== 'unknown') {
	            registry.instances[i].kind = kind;
	          }
	          return;
	        }
	      }
	      // Bounded by dropping the OLDEST. A single-page app that rebuilds its map per route would
	      // otherwise fill the list with dead maps and never record the one on screen — and a
	      // detached map still answers `getCenter()` perfectly happily.
	      registry.instances.push({ kind: kind, instance: instance });
	      if (registry.instances.length > 24) { registry.instances.shift(); }
	    } catch (e) { /* a getter threw; nothing to record */ }
	  }

	  function note(name) {
	    try { if (registry.libraries.indexOf(name) < 0) { registry.libraries.push(name); } } catch (e) {}
	  }

	  // Runs `onValue` once a global appears, by POLLING rather than by installing an accessor.
	  //
	  // Accessors were the obvious implementation and they broke real pages. Redefining `window.L`,
	  // `window.define` and friends as get/set pairs interferes with how bundled code initialises
	  // its own namespaces: americanamap.org died with "Cannot set properties of undefined" and
	  // rendered nothing at all. Reading a coordinate is never worth breaking the page the user is
	  // trying to look at.
	  //
	  // Polling cannot break anything because it touches nothing. The cost is catching a library a
	  // few milliseconds after it loads, which only matters for a map constructed in that window --
	  // and the bind trap and the duck-typed scan both still reach those.
	  var pollers = [];
	  function whenGlobal(name, onValue) {
	    try {
	      if (window[name] !== undefined && window[name] !== null) { onValue(window[name]); return; }
	      pollers.push({ name: name, onValue: onValue, done: false });
	    } catch (e) {}
	  }

	  var pollTicks = 0;
	  var pollTimer = setInterval(function () {
	    pollTicks += 1;
	    var outstanding = 0;
	    for (var i = 0; i < pollers.length; i++) {
	      var entry = pollers[i];
	      if (entry.done) { continue; }
	      var value;
	      try { value = window[entry.name]; } catch (e) { entry.done = true; continue; }
	      if (value !== undefined && value !== null) {
	        entry.done = true;
	        try { entry.onValue(value); } catch (e) {}
	      } else {
	        outstanding += 1;
	      }
	    }
	    // Libraries load during start-up. After that this is only a timer nobody needs.
	    if (outstanding === 0 || pollTicks > 300) { clearInterval(pollTimer); }
	    // 20ms, not 50: the gap between a module loader being defined and first used is short, and
	    // a wrapper installed after the first `require([...])` call misses the module it wanted.
	    // This is the cost of polling instead of installing an accessor — worth paying, since the
	    // accessor broke real pages outright, but worth minimising.
	  }, 20);

	  // Waits for a property to appear on a namespace that was assigned empty.
	  //
	  // Polled for the same reason as the globals above: several UMD builds publish their namespace
	  // first and populate it afterwards, and redefining a property on someone else's object to
	  // notice that is exactly what broke pages.
	  function watchNamespace(namespace, key, onDefined) {
	    try {
	      if (namespace[key] !== undefined) { onDefined(); return; }
	      var attempts = 0;
	      var timer = setInterval(function () {
	        attempts += 1;
	        var present = false;
	        try { present = namespace[key] !== undefined; } catch (e) { clearInterval(timer); return; }
	        if (present) {
	          clearInterval(timer);
	          try { onDefined(); } catch (e) {}
	        } else if (attempts > 120) {
	          clearInterval(timer);
	        }
	      }, 50);
	    } catch (e) {}
	  }

	  // Records every instance of a constructor without disturbing its prototype chain or statics.
	  function traceConstructor(owner, key, kind) {
	    try {
	      var original = owner[key];
	      if (typeof original !== 'function' || original.__aiaTraced) { return; }
	      var traced = new Proxy(original, {
	        construct: function (target, args, newTarget) {
	          var instance = Reflect.construct(target, args, newTarget);
	          record(kind, instance);
	          return instance;
	        }
	      });
	      try {
	        Object.defineProperty(traced, '__aiaTraced', { value: true, enumerable: false });
	      } catch (e) {}
	      owner[key] = traced;
	    } catch (e) {}
	  }

	  // Announce this frame so native can probe it later. Many map pages put the map in an iframe,
	  // and WebKit offers no way to enumerate frames — a `WKFrameInfo` only ever arrives with a
	  // message, so a frame that never speaks can never be asked.
	  try {
	    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.aiaMapFrame) {
	      window.webkit.messageHandlers.aiaMapFrame.postMessage('here');
	    }
	  } catch (e) {}

	  // --- The one hook that reaches a module-scoped map ------------------------------------------
	  //
	  // An ESM-bundled map assigns no global and leaves no property on any DOM node — measured on
	  // openlayers.org and maplibre.org, where the container, the canvas and every ancestor have
	  // zero own properties. Every other candidate hook yields an *element* or an opaque closure.
	  //
	  // `bind` yields the object. Every one of these libraries binds methods to its map during
	  // construction: Leaflet through `Util.bind`/`requestAnimFrame(fn, this)`, OpenLayers with
	  // `this.handleBrowserEvent.bind(this)`, MapLibre and Mapbox through `bindAll([...], this)`.
	  // The bound `this` IS the map, and its prototype methods already exist mid-construction, so
	  // duck-typing the receiver identifies it.
	  try {
	    var originalBind = Function.prototype.bind;
	    if (!originalBind.__aiaTraced) {
	      var boundSeen = new WeakSet();
	      // ArcGIS and other large apps bind constantly during start-up, so this runs on a very hot
	      // path. It must stay nearly free, and it must not run forever: the trap uninstalls itself
	      // once it has found a map or seen enough calls to conclude it will not. A slow map page is
	      // a worse outcome than a missed coordinate.
	      var inspections = 0;
	      var found = false;
	      function restoreBind() {
	        try {
	          // Only if OURS is still the installed value. A page that replaced `bind` during the
	          // window owns it now, and restoring unconditionally would erase that page's code —
	          // the exact damage this trap is supposed to avoid causing.
	          if (Function.prototype.bind !== traced) { return; }
	          Object.defineProperty(Function.prototype, 'bind', {
	            value: originalBind, writable: true, configurable: true, enumerable: false
	          });
	        } catch (e) {}
	      }
	      var traced = new Proxy(originalBind, {
	        apply: function (target, thisArg, args) {
	          try {
	            var receiver = args[0];
	            if (receiver && typeof receiver === 'object' && !boundSeen.has(receiver)) {
	              boundSeen.add(receiver);
	              inspections += 1;
	              if (typeof receiver.getCenter === 'function' ||
	                  typeof receiver.getView === 'function' ||
	                  (receiver.scene && receiver.camera)) {
	                note('bound');
	                record('unknown', receiver);
	                found = true;
	              }
	              if (found || inspections > 4000) { restoreBind(); }
	            }
	          } catch (e) { /* a hostile getter; binding must still work */ }
	          return Reflect.apply(target, thisArg, args);
	        }
	      });
	      try {
	        Object.defineProperty(traced, '__aiaTraced', { value: true, enumerable: false });
	      } catch (e) {}
	      // Writable and configurable so a page that replaces `bind` itself still wins.
	      Object.defineProperty(Function.prototype, 'bind', {
	        value: traced, writable: true, configurable: true, enumerable: false
	      });
	      // Uninstalled after a few seconds no matter what. Maps are constructed during start-up, so
	      // a trap still in place a minute later can only be a tax: `bind` is on the hot path of
	      // essentially every framework, and a page that binds few distinct objects would otherwise
	      // never reach the inspection cap and never let go. Whatever it has not caught by now, it
	      // will not catch.
	      try { setTimeout(restoreBind, 4000); } catch (e) {}
	    }
	  } catch (e) {}

	  // --- Leaflet -------------------------------------------------------------------------------
	  // `L.map(...)` is a factory closing over an internal class, so wrapping `L.Map` would miss the
	  // usual call. `addInitHook` is Leaflet's own documented extension point and fires for every
	  // map however it was constructed.
	  function hookLeaflet(L) {
	    try {
	      if (L && L.Map && typeof L.Map.addInitHook === 'function' && !L.Map.__aiaHooked) {
	        L.Map.addInitHook(function () { record('leaflet', this); });
	        try { Object.defineProperty(L.Map, '__aiaHooked', { value: true, enumerable: false }); } catch (e) {}
	        return true;
	      }
	    } catch (e) {}
	    return false;
	  }

	  whenGlobal('L', function (L) {
	    note('leaflet');
	    // Leaflet 1.8 and earlier do `factory(global.L = {})`: the global is assigned EMPTY and
	    // filled afterwards, so `L.Map` does not exist yet at this point. Waiting for `Map` to be
	    // defined on the namespace catches those builds; 1.9 assigns the finished object and is
	    // caught by the direct call.
	    if (hookLeaflet(L)) { return; }
	    watchNamespace(L, 'Map', function () { hookLeaflet(L); });
	  });

	  // --- OpenLayers 3+ and 2 -------------------------------------------------------------------
	  whenGlobal('ol', function (ns) {
	    note('openlayers');
	    traceConstructor(ns, 'Map', 'openlayers');
	    watchNamespace(ns, 'Map', function () { traceConstructor(ns, 'Map', 'openlayers'); });
	  });
	  whenGlobal('OpenLayers', function (o) { note('openlayers2'); traceConstructor(o, 'Map', 'openlayers2'); });

	  // --- MapLibre / Mapbox GL ------------------------------------------------------------------
	  whenGlobal('maplibregl', function (ns) {
	    note('maplibre');
	    traceConstructor(ns, 'Map', 'maplibre');
	    watchNamespace(ns, 'Map', function () { traceConstructor(ns, 'Map', 'maplibre'); });
	  });
	  whenGlobal('mapboxgl', function (ns) {
	    note('maplibre');
	    traceConstructor(ns, 'Map', 'maplibre');
	    watchNamespace(ns, 'Map', function () { traceConstructor(ns, 'Map', 'maplibre'); });
	  });

	  // --- Google Maps ---------------------------------------------------------------------------
	  // The loader creates an empty `google` namespace first and installs `maps.Map` later, so the
	  // constructor has to be traced through a second, nested wait.
	  whenGlobal('google', function (google) {
	    note('googlemaps');
	    var attempts = 0;
	    var timer = setInterval(function () {
	      attempts += 1;
	      try {
	        if (google && google.maps && google.maps.Map) {
	          traceConstructor(google.maps, 'Map', 'googlemaps');
	          clearInterval(timer);
	        }
	      } catch (e) { clearInterval(timer); }
	      if (attempts > 100) { clearInterval(timer); }
	    }, 100);
	  });

	  // --- Potree and deck.gl --------------------------------------------------------------------
	  // Both are common in exactly this app's domain: Potree renders the LIDAR point clouds these
	  // heritage portals publish, and deck.gl sits on top of MapLibre in newer viewers.
	  whenGlobal('Potree', function (P) {
	    note('potree');
	    traceConstructor(P, 'Viewer', 'potree');
	    watchNamespace(P, 'Viewer', function () { traceConstructor(P, 'Viewer', 'potree'); });
	  });
	  whenGlobal('deck', function (d) {
	    note('deckgl');
	    traceConstructor(d, 'Deck', 'deckgl');
	    watchNamespace(d, 'Deck', function () { traceConstructor(d, 'Deck', 'deckgl'); });
	  });

	  // --- Cesium --------------------------------------------------------------------------------
	  whenGlobal('Cesium', function (C) {
	    note('cesium');
	    traceConstructor(C, 'Viewer', 'cesium');
	    traceConstructor(C, 'CesiumWidget', 'cesium');
	  });

	  // --- ArcGIS -----------------------------------------------------------------------------
	  //
	  // Deliberately NOT by wrapping the page's module loader.
	  //
	  // An earlier version replaced `window.require` and `window.define` with proxies to trace
	  // `esri/*` modules as they were delivered. It was removed after checking what actually finds
	  // ArcGIS on real pages: the classic WebAppViewer keeps its map on `window._viewerMap` (the
	  // duck-typed scan), current ESM builds publish views on `$arcgis.views`, and component pages
	  // expose `arcgis-map.view`. The loader trap was the mechanism for none of them.
	  //
	  // It was also the most invasive hook left: replacing a page's module loader risks breaking the
	  // application outright, and this feature is not worth a broken page. Reading a coordinate must
	  // never cost the user the thing they were looking at.

	  } catch (e) {
	    // Nothing to report and nowhere to report it: the page is what matters, and it continues.
	  }
	}());
	"""#

	/// Evaluated at finding capture, as an async function body (`callAsyncJavaScript`).
	///
	/// Returns a plain object — never a string to be parsed by evaluation — describing the best
	/// candidate found, plus page metadata. Its own cooperative deadline matters more than the
	/// native timeout: cancelling a Swift task cannot stop JavaScript that is already running, so
	/// the script must agree to stop on its own.
	static let probe = #"""
	var DEADLINE = Date.now() + 3500;
	var out = { library: null, source: null, latitude: null, longitude: null, zoom: null,
	            canonical: null, metaLatitude: null, metaLongitude: null, libraries: [],
	            // The viewport in the view's OWN coordinate system, unprojected and unconverted.
	            // Not a location — it is the raw material for refreshing viewport numbers the URL
	            // already carries, which is how an app that never rewrites its address bar can still
	            // yield a URL that reopens the exact view.
	            nativeExtent: null, nativeCenter: null, nativeWkid: null,
	            // A coordinate the PAGE ITSELF displays, copied verbatim. Whatever format and datum
	            // the site chose travels with it, so no conversion is involved.
	            displayedCoordinate: null };

	function expired() { return Date.now() > DEADLINE; }
	function num(v) { return (typeof v === 'number' && isFinite(v)) ? v : null; }

	function areaOf(element) {
	  try {
	    if (!element || !element.getBoundingClientRect) { return 0; }
	    var r = element.getBoundingClientRect();
	    return Math.max(0, r.width) * Math.max(0, r.height);
	  } catch (e) { return 0; }
	}

	// --- Candidate collection -------------------------------------------------------------------

	var candidates = [];
	function offer(kind, instance) {
	  try {
	    if (!instance) { return; }
	    for (var i = 0; i < candidates.length; i++) {
	      if (candidates[i].instance === instance) { return; }
	    }
	    if (candidates.length < 24) { candidates.push({ kind: kind, instance: instance }); }
	  } catch (e) {}
	}

	// 1. Instances captured at construction time.
	var registry = null;
	try { registry = window.__aiaMapRegistry; } catch (e) {}
	// One `try` each, deliberately. The binding is non-writable, but the OBJECT behind it is not:
	// its members are ordinary properties a page can redefine as throwing getters. Sharing a `try`
	// meant poisoning the cheaper member (`libraries`) also skipped the loop below it, so a page
	// could hide its own map from the probe with one line (found while making the hostile fixture
	// actually hostile).
	try {
	  if (registry) {
	    // Truncated HERE, not after decoding: the registry is page-visible, so a page can put
	    // arbitrarily long strings in it, and capping only the count still lets the payload cross
	    // the bridge before anything measures it.
	    out.libraries = (registry.libraries || []).slice(0, 12).map(function (name) {
	      return String(name).slice(0, 40);
	    });
	  }
	} catch (e) {}
	try {
	  if (registry) {
	    for (var i = 0; i < registry.instances.length; i++) {
	      offer(registry.instances[i].kind, registry.instances[i].instance);
	    }
	  }
	} catch (e) {}

	// 2. ArcGIS web components expose their view as public API. This is the only DOM container that
	//    genuinely yields an instance; Leaflet, OpenLayers, MapLibre and Google do not expose theirs,
	//    so their CSS classes only prove the library is present.
	try {
	  var components = document.querySelectorAll('arcgis-map, arcgis-scene');
	  for (var c = 0; c < components.length; c++) {
	    if (components[c].view) { offer('arcgis', components[c].view); }
	  }
	} catch (e) {}

	// 2b. The ESM ArcGIS view registry.
	//
	// Current ArcGIS builds publish their live views on `$arcgis.views`, an Esri `Collection`. This
	// is the one hook that reaches the modern ESM apps at all: they expose no AMD loader, no
	// `__esri`, nothing on `window`, and their `.esri-view` element carries no back-reference — but
	// the SDK itself keeps a list. Verified on map.apps (Wind-Atlas), where it yields a ready view
	// in EPSG:25832 while every other strategy found nothing.
	try {
	  var registryViews = window.$arcgis && window.$arcgis.views;
	  if (registryViews) {
	    var collected = [];
	    if (typeof registryViews[Symbol.iterator] === 'function') {
	      var iterated = 0;
	      for (var candidateView of registryViews) {
	        collected.push(candidateView);
	        iterated += 1;
	        if (iterated > 8) { break; }
	      }
	    } else if (registryViews._items && registryViews._items.length) {
	      collected = Array.prototype.slice.call(registryViews._items, 0, 8);
	    }
	    for (var cv = 0; cv < collected.length; cv++) { offer('arcgis', collected[cv]); }
	  }
	} catch (e) {}

	// 3. Framework back-reference scan: the bundled majority.
	//    Most Leaflet and OpenLayers sites in the target catalogue are React/Vue bundles whose map
	//    lives in module scope, invisible to every global trap. The framework, however, keeps its own
	//    expandos on the container element, and the map object is reachable through them.
	//
	//    This is the one strategy built on framework *internals* rather than public API, so the
	//    property names are version-unstable. It runs last, fails closed, and is pinned by its own
	//    harness pages so a rename shows up as a failing test rather than as silent coverage loss.
	function looksLikeMap(value) {
	  try {
	    if (!value || typeof value !== 'object') { return false; }
	    return typeof value.getCenter === 'function'
	      || typeof value.getView === 'function'
	      // ArcGIS views answer neither, but have a readiness promise and a spatial reference.
	      || (typeof value.when === 'function' && 'spatialReference' in value)
	      // Cesium, and Potree's viewer, expose a scene with a camera or a view.
	      || (value.scene && (value.camera || value.scene.view))
	      // deck.gl.
	      || (value.viewManager && typeof value.viewManager.getViewports === 'function')
	      // ArcGIS JS 3.x: a Map has an extent and a zoom level, and none of the accessors above.
	      || (value.extent && typeof value.getLevel === 'function')
	      || (value.geographicExtent && typeof value.geographicExtent.getCenter === 'function');
	  } catch (e) { return false; }
	}

	function searchNode(node, depth, seen) {
	  if (!node || depth > 6 || expired()) { return null; }
	  try {
	    if (seen.indexOf(node) >= 0) { return null; }
	    if (seen.length > 400) { return null; }
	    seen.push(node);
	  } catch (e) { return null; }
	  try {
	    for (var key in node) {
	      if (expired()) { return null; }
	      var value;
	      try { value = node[key]; } catch (e) { continue; }
	      if (looksLikeMap(value)) { return value; }
	      // Never descend into a DOM node or a window. Enumerating an element reads accessors like
	      // `innerText` and `offsetTop`, which force layout and serialise the subtree — on a large
	      // page that is a visible stall, and the map is never inside one anyway.
	      try {
	        if (value instanceof Node || value instanceof Window) { continue; }
	      } catch (e) { continue; }
	      if (value && typeof value === 'object' && depth < 6) {
	        var found = searchNode(value, depth + 1, seen);
	        if (found) { return found; }
	      }
	    }
	  } catch (e) {}
	  return null;
	}

	try {
	  var containers = document.querySelectorAll(
	    '.leaflet-container, .ol-viewport, .maplibregl-map, .mapboxgl-map'
	  );
	  for (var n = 0; n < containers.length && n < 6 && !expired(); n++) {
	    var element = containers[n];
	    var kind = element.className.indexOf('leaflet') >= 0 ? 'leaflet'
	             : element.className.indexOf('ol-') >= 0 ? 'openlayers' : 'maplibre';
	    for (var prop in element) {
	      if (prop.indexOf('__reactFiber') !== 0 && prop.indexOf('__reactProps') !== 0 &&
	          prop !== '__vue__' && prop !== '__vueParentComponent') { continue; }
	      var root;
	      try { root = element[prop]; } catch (e) { continue; }
	      var found = searchNode(root, 0, []);
	      if (found) { offer(kind, found); break; }
	    }
	  }
	} catch (e) {}

	// 4. Duck-typed scan of globals: custom wrappers and libraries nobody listed.
	try {
	  var keys = Object.keys(window);
	  for (var k = 0; k < keys.length && k < 400 && !expired(); k++) {
	    var value;
	    try { value = window[keys[k]]; } catch (e) { continue; }
	    if (looksLikeMap(value)) { offer('unknown', value); }
	  }
	} catch (e) {}

	// --- Reading a centre ------------------------------------------------------------------------

	// A map torn out of the DOM still answers `getCenter()`, so "is it on screen" has to be asked
	// explicitly or a stale route's map can outrank the live one.
	function isAttached(element) {
	  // `isConnected`, not `document.contains`: the latter is false for any node inside a shadow
	  // root, and ArcGIS web components put their whole view in one — so the contains() form threw
	  // away exactly the maps this tier exists to find.
	  try { return !!element && element.isConnected === true; } catch (e) { return false; }
	}

	function containerOf(kind, map) {
	  try {
	    if (typeof map.getContainer === 'function') { return map.getContainer(); }
	    if (typeof map.getTargetElement === 'function') { return map.getTargetElement(); }
	    if (typeof map.getDiv === 'function') { return map.getDiv(); }
	    if (map.container) { return map.container; }
	  } catch (e) {}
	  return null;
	}

	async function readCentre(kind, map, viewport) {
	  // Leaflet: LatLng is WGS-84 by API contract, whatever projection the tiles use.
	  try {
	    if (typeof map.getCenter === 'function') {
	      var c = map.getCenter();
	      // Google Maps returns a LatLng whose lat/lng are METHODS, not properties. Without this the
	      // Google adapter reads `undefined` and silently never produces a reading.
	      if (c && typeof c.lat === 'function' && typeof c.lng === 'function') {
	        var gLat = c.lat();
	        var gLng = c.lng();
	        if (num(gLat) !== null && num(gLng) !== null) {
	          var gZoom = (typeof map.getZoom === 'function') ? num(map.getZoom()) : null;
	          return { latitude: gLat, longitude: gLng, zoom: gZoom, library: 'googlemaps' };
	        }
	      }
	      if (c && num(c.lat) !== null && num(c.lng) !== null) {
	        var zoom = (typeof map.getZoom === 'function') ? num(map.getZoom()) : null;
	        // `{lat, lng}` from `getCenter()` is Leaflet's LatLng. The shape identifies the library
	        // more reliably than which trap happened to see the instance first.
	        return { latitude: c.lat, longitude: c.lng, zoom: zoom,
	                 library: kind === 'unknown' ? 'leaflet' : kind };
	      }
	      // OpenLayers 2 returns a LonLat in the map's own projection.
	      if (c && num(c.lon) !== null && num(c.lat) !== null && window.OpenLayers) {
	        var wgs = c.clone().transform(map.getProjectionObject(), new window.OpenLayers.Projection('EPSG:4326'));
	        if (num(wgs.lat) !== null && num(wgs.lon) !== null) {
	          return { latitude: wgs.lat, longitude: wgs.lon, zoom: num(map.getZoom()), library: 'openlayers2' };
	        }
	      }
	    }
	  } catch (e) {}

	  // OpenLayers 3+: ask OpenLayers to convert, using its own projection registry.
	  try {
	    if (typeof map.getView === 'function') {
	      var view = map.getView();
	      var centre = view.getCenter();
	      if (centre && centre.length >= 2) {
	        var projection = view.getProjection();
	        var code = projection && projection.getCode ? projection.getCode() : null;
	        if (window.ol && window.ol.proj && typeof window.ol.proj.toLonLat === 'function') {
	          var lonLat = window.ol.proj.toLonLat(centre, projection);
	          return { latitude: lonLat[1], longitude: lonLat[0], zoom: num(view.getZoom()), library: 'openlayers' };
	        }
	        // Bundled OpenLayers with no global: usable only when the view is already geographic,
	        // because converting it ourselves is exactly the arithmetic this design refuses.
	        if (code === 'EPSG:4326' || code === 'CRS:84') {
	          return { latitude: centre[1], longitude: centre[0], zoom: num(view.getZoom()), library: 'openlayers' };
	        }
	      }
	    }
	  } catch (e) {}

	  // ArcGIS views initialise asynchronously. Read too early — which is most of the time, because a
	  // finding is captured the moment the user taps — and `center` is simply undefined: not a
	  // projection problem, nothing to project. `when()` is the SDK's own readiness promise.
	  //
	  // This is the case every hand-written ArcGIS fixture missed, because a fixture invents a view
	  // that is ready by construction.
	  try {
	    if (map.ready === false && typeof map.when === 'function') {
	      await Promise.race([
	        Promise.resolve(map.when()).catch(function () { return null; }),
	        new Promise(function (r) { setTimeout(r, 1500); })
	      ]);
	    }
	  } catch (e) {}

	  // ArcGIS: `latitude`/`longitude` are populated only for geographic and Web Mercator views, and
	  // return null for a national grid such as CUZK's S-JTSK. Those need Esri's own projection.
	  try {
	    if (map.center && (map.center.spatialReference || map.center.x !== undefined)) {
	      var point = map.center;
	      if (num(point.latitude) !== null && num(point.longitude) !== null) {
	        return { latitude: point.latitude, longitude: point.longitude, zoom: num(map.zoom), library: 'arcgis' };
	      }
	      // Recorded BEFORE attempting projection. Projection is slow and usually unavailable, and
	      // anything after it may run past the script's deadline — so the viewport, which is free
	      // and always present once the view is ready, must be banked first. Without this the
	      // `extent=` refresh was lost on exactly the apps it exists for.
	      readNativeViewport(map, viewport);
	      var projected = await projectWithEsri(point);
	      if (projected) {
	        return { latitude: projected.latitude, longitude: projected.longitude, zoom: num(map.zoom), library: 'arcgis' };
	      }
	    }
	    // ArcGIS 3.x keeps a geographic extent alongside the projected one — already WGS-84, so no
	    // projection module is needed at all. This is the classic WebAppViewer path.
	    if (map.geographicExtent && typeof map.geographicExtent.getCenter === 'function') {
	      readNativeViewport(map, viewport);
	      var g = map.geographicExtent.getCenter();
	      if (num(g.y) !== null && num(g.x) !== null) {
	        var level = (typeof map.getLevel === 'function') ? num(map.getLevel()) : null;
	        return { latitude: g.y, longitude: g.x, zoom: level, library: 'arcgis' };
	      }
	    }
	  } catch (e) {}

	  // deck.gl: the viewport already carries degrees.
	  try {
	    if (map.viewManager && typeof map.viewManager.getViewports === 'function') {
	      var viewports = map.viewManager.getViewports();
	      if (viewports && viewports.length) {
	        var vp = viewports[0];
	        if (num(vp.latitude) !== null && num(vp.longitude) !== null) {
	          return { latitude: vp.latitude, longitude: vp.longitude, zoom: num(vp.zoom), library: 'deckgl' };
	        }
	      }
	    }
	  } catch (e) {}

	  // Cesium: radians to degrees is a unit change within one datum, not a reprojection.
	  try {
	    var camera = map.camera || (map.scene && map.scene.camera);
	    if (camera && camera.positionCartographic) {
	      var p = camera.positionCartographic;
	      if (num(p.latitude) !== null && num(p.longitude) !== null) {
	        return {
	          latitude: p.latitude * 180 / Math.PI,
	          longitude: p.longitude * 180 / Math.PI,
	          zoom: null,
	          library: 'cesium'
	        };
	      }
	    }
	  } catch (e) {}

	  return null;
	}

	// Uses the page's own ArcGIS SDK to project to WGS-84. Never our arithmetic.
	//
	// Two entry points, because ArcGIS ships two module systems and a page has only one of them.
	// The older AMD builds expose `require`; the current ESM builds expose `$arcgis.import` and no
	// loader at all — cuzk.cz is the second kind, which is why an AMD-only path found nothing there
	// while the map object itself was sitting in the DOM the whole time.
	//
	// The module and method names differ across SDK versions too, so each shape is tried and the
	// first that yields a finite pair wins. Everything fails closed.
	function projectWithEsri(point) {
	  return new Promise(function (resolve) {
	    var settled = false;
	    function finish(value) { if (!settled) { settled = true; resolve(value); } }
	    function accept(result) {
	      try {
	        if (result && num(result.latitude) !== null && num(result.longitude) !== null) {
	          finish({ latitude: result.latitude, longitude: result.longitude });
	          return true;
	        }
	      } catch (e) {}
	      return false;
	    }
	    // Short: on a page that exposes no projection module this always runs to completion, and the
	    // viewport has already been banked, so waiting longer buys nothing.
	    setTimeout(function () { finish(null); }, 500);

	    // Web Mercator needs no projection module at all.
	    try {
	      var wkid = point.spatialReference && (point.spatialReference.wkid || point.spatialReference.latestWkid);
	      if (wkid === 4326 && accept({ latitude: point.y, longitude: point.x })) { return; }
	    } catch (e) {}

	    // Modern ESM builds.
	    try {
	      if (window.$arcgis && typeof window.$arcgis.import === 'function') {
	        Promise.resolve(window.$arcgis.import('@arcgis/core/geometry/projection.js'))
	          .then(function (projection) {
	            return Promise.resolve(projection.load()).then(function () {
	              accept(projection.project(point, { wkid: 4326 }));
	            });
	          })
	          .catch(function () {
	            Promise.resolve(window.$arcgis.import('@arcgis/core/geometry/operators/projectOperator.js'))
	              .then(function (op) {
	                return Promise.resolve(op.load ? op.load() : null).then(function () {
	                  accept(op.execute(point, { wkid: 4326 }));
	                });
	              })
	              .catch(function () {});
	          });
	      }
	    } catch (e) {}

	    // Older AMD builds.
	    try {
	      if (typeof window.require === 'function') {
	        window.require(['esri/geometry/projection', 'esri/geometry/SpatialReference'],
	          function (projection, SpatialReference) {
	            try {
	              Promise.resolve(projection.load()).then(function () {
	                accept(projection.project(point, new SpatialReference({ wkid: 4326 })));
	              }).catch(function () {});
	            } catch (e) {}
	          });
	      }
	    } catch (e) {}
	  });
	}

	// Largest rendered map wins: a page with an inset minimap must not report the minimap's centre.
	candidates = candidates.filter(function (candidate) {
	  var element = containerOf(candidate.kind, candidate.instance);
	  // No container at all is not disqualifying — several adapters expose none — but a container
	  // that has been detached means the map is gone from the page.
	  return element === null || element === undefined || isAttached(element);
	});
	candidates.sort(function (a, b) {
	  return areaOf(containerOf(b.kind, b.instance)) - areaOf(containerOf(a.kind, a.instance));
	});

	// The viewport as the app itself holds it. Read from the same instance that produced the
	// reading, so the two cannot describe different maps.
	// Written into a candidate-local object, never straight into `out`.
	//
	// Banking global state while walking candidates let a viewport from the largest map be paired
	// with a coordinate from a smaller one — the URL would then be refreshed from a different map
	// than the coordinate came from, and "largest rendered map wins" would quietly not be true.
	// One candidate is committed, whole.
	function readNativeViewport(map, into) {
	  try {
	    var extent = map.extent;
	    if (extent && num(extent.xmin) !== null && num(extent.ymin) !== null &&
	        num(extent.xmax) !== null && num(extent.ymax) !== null) {
	      into.nativeExtent = [extent.xmin, extent.ymin, extent.xmax, extent.ymax];
	      try {
	        var esr = extent.spatialReference;
	        if (esr && !into.nativeWkid) { into.nativeWkid = esr.latestWkid || esr.wkid || null; }
	        if (!into.nativeCenter && typeof extent.getCenter === 'function') {
	          var ec = extent.getCenter();
	          if (ec && num(ec.x) !== null && num(ec.y) !== null) { into.nativeCenter = [ec.x, ec.y]; }
	        }
	      } catch (e) {}
	    }
	    // Potree: a point cloud sits in its survey's own projected system, which the scene names.
	    // Read here rather than in `readCentre`, which returns null for it — a viewport banked there
	    // is discarded, so the adapter looked present and did nothing.
	    if (!into.nativeCenter && map.scene && map.scene.view && map.scene.view.position) {
	      var potreePosition = map.scene.view.position;
	      if (num(potreePosition.x) !== null && num(potreePosition.y) !== null) {
	        into.nativeCenter = [potreePosition.x, potreePosition.y];
	        try {
	          var clouds = map.scene.pointclouds;
	          var projection = clouds && clouds.length ? clouds[0].projection : null;
	          var epsg = projection ? String(projection).match(/EPSG[:\s]*(\d+)/i) : null;
	          if (epsg) { into.nativeWkid = parseInt(epsg[1], 10); }
	        } catch (e) {}
	      }
	    }

	    var centre = map.center;
	    if (centre && num(centre.x) !== null && num(centre.y) !== null) {
	      into.nativeCenter = [centre.x, centre.y];
	      try {
	        var sr = centre.spatialReference || (map.spatialReference || null);
	        if (sr) { into.nativeWkid = sr.latestWkid || sr.wkid || null; }
	      } catch (e) {}
	    }
	    if (!into.nativeCenter && typeof map.getView === 'function') {
	      var view = map.getView();
	      var c = view.getCenter();
	      if (c && c.length >= 2 && num(c[0]) !== null && num(c[1]) !== null) {
	        into.nativeCenter = [c[0], c[1]];
	        try {
	          var code = view.getProjection && view.getProjection().getCode();
	          // Only an EPSG code is a code we can name. `CRS:84` would otherwise be read as
	          // "EPSG:84", which is a different thing entirely.
	          var epsg = code ? String(code).match(/^EPSG:(\d+)$/i) : null;
	          if (epsg) { into.nativeWkid = parseInt(epsg[1], 10); }
	        } catch (e) {}
	      }
	    }
	  } catch (e) {}
	}

	// One candidate is committed whole: its coordinate AND its viewport, or neither. Mixing them
	// would refresh the URL from a different map than the coordinate came from.
	for (var q = 0; q < candidates.length && !expired(); q++) {
	  var viewport = { nativeExtent: null, nativeCenter: null, nativeWkid: null };
	  var reading = await readCentre(candidates[q].kind, candidates[q].instance, viewport);
	  if (reading) {
	    readNativeViewport(candidates[q].instance, viewport);
	    out.latitude = reading.latitude;
	    out.longitude = reading.longitude;
	    out.zoom = reading.zoom;
	    out.library = reading.library;
	    out.source = 'instance';
	    out.nativeExtent = viewport.nativeExtent;
	    out.nativeCenter = viewport.nativeCenter;
	    out.nativeWkid = viewport.nativeWkid;
	    break;
	  }
	}

	// A projected view we cannot convert still knows where it is looking. Recording its viewport
	// costs nothing and is what lets the URL be refreshed even with no coordinate to show.
	// Deliberately NOT gated on `expired()`: reading an already-loaded object costs nothing, and the
	// deadline exists to bound waiting on the page, not to skip work that needs no waiting.
	// No coordinate anywhere, but a map may still know where it is looking. Largest first, and the
	// first that answers is taken whole.
	if (out.nativeExtent === null && out.nativeCenter === null) {
	  for (var r = 0; r < candidates.length; r++) {
	    var fallbackViewport = { nativeExtent: null, nativeCenter: null, nativeWkid: null };
	    readNativeViewport(candidates[r].instance, fallbackViewport);
	    if (fallbackViewport.nativeExtent !== null || fallbackViewport.nativeCenter !== null) {
	      out.nativeExtent = fallbackViewport.nativeExtent;
	      out.nativeCenter = fallbackViewport.nativeCenter;
	      out.nativeWkid = fallbackViewport.nativeWkid;
	      break;
	    }
	  }
	}

	// --- A coordinate the page is showing the user ------------------------------------------------
	//
	// Deliberately last: it is the weakest evidence, because text on a page can be a coordinate
	// readout, a search box, a legend, or a form field. Everything below narrows it to text that
	// looks like a coordinate, is visible, is short, and sits in a small element — a readout, not a
	// paragraph. Taken verbatim; whatever datum or format the site chose travels with it.
	try {
	  if (out.latitude === null) {
	    var coordinatePatterns = [
	      /^-?\d{1,3}[.,]\d{4,}\s*[,;]\s*-?\d{1,3}[.,]\d{4,}$/,
	      /^\d{1,3}\s*°[^,;]{0,18}[NSEW]?\s*[,;]\s*\d{1,3}\s*°[^,;]{0,18}[NSEW]?$/i,
	      /^[NSEW]\s*\d{1,3}[.,°][^,;]{0,18}[,;]\s*[NSEW]\s*\d{1,3}[.,°]/i
	    ];
	    var best = null;
	    var seen = 0;
	    (function scan(root, depth) {
	      if (depth > 6 || best !== null || expired() || seen > 4000) { return; }
	      var elements;
	      try { elements = root.querySelectorAll('*'); } catch (e) { return; }
	      for (var i = 0; i < elements.length && best === null; i++) {
	        // Checked inside the loop: this runs on every capture that found no coordinate, and a
	        // 50,000-node page would otherwise be walked in full, measuring each candidate.
	        if (expired() || seen > 4000) { return; }
	        seen += 1;
	        var element = elements[i];
	        try {
	          if (element.shadowRoot) { scan(element.shadowRoot, depth + 1); }
	          var own = '';
	          for (var n = 0; n < element.childNodes.length; n++) {
	            if (element.childNodes[n].nodeType === 3) { own += element.childNodes[n].nodeValue; }
	          }
	          own = own.replace(/\s+/g, ' ').trim();
	          if (own.length < 7 || own.length > 60) { continue; }
	          var rect = element.getBoundingClientRect();
	          if (rect.width <= 0 || rect.height <= 0 || rect.height > 80) { continue; }
	          for (var p = 0; p < coordinatePatterns.length; p++) {
	            if (coordinatePatterns[p].test(own)) { best = own; break; }
	          }
	        } catch (e) {}
	      }
	    }(document, 0));
	    if (best) { out.displayedCoordinate = best.slice(0, 60); }
	  }
	} catch (e) {}

	// --- Page metadata ---------------------------------------------------------------------------
	try {
	  var canonical = document.querySelector('link[rel="canonical"]');
	  if (canonical && canonical.href) { out.canonical = String(canonical.href).slice(0, 2000); }

	  function metaContent(selector) {
	    var el = document.querySelector(selector);
	    return el && el.content ? String(el.content).slice(0, 120) : null;
	  }
	  var metaLat = metaContent('meta[property="og:latitude"], meta[name="og:latitude"], meta[name="ICBM"]');
	  var metaLon = metaContent('meta[property="og:longitude"], meta[name="og:longitude"]');
	  var position = metaContent('meta[name="geo.position"]');
	  if (position && position.indexOf(';') > 0) {
	    var halves = position.split(';');
	    metaLat = halves[0];
	    metaLon = halves[1];
	  }
	  if (metaLat !== null && metaLon !== null) {
	    out.metaLatitude = parseFloat(metaLat);
	    out.metaLongitude = parseFloat(metaLon);
	    if (!isFinite(out.metaLatitude) || !isFinite(out.metaLongitude)) {
	      out.metaLatitude = null;
	      out.metaLongitude = null;
	    }
	  }
	} catch (e) {}

	return out;
	"""#
}
