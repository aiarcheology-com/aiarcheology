/*
 * Renders a shared finding from the URL fragment (AIA-0650).
 *
 * Every value here is attacker-controlled: anyone can type a URL. Two rules make that safe,
 * and both are absolute.
 *
 *   1. Text reaches the document ONLY through textContent. There is no innerHTML,
 *      insertAdjacentHTML, document.write or template-string markup anywhere in this file,
 *      so a title of `<img src=x onerror=...>` renders as those literal characters.
 *   2. A URL becomes an href ONLY after it parses and its protocol is exactly `https:`.
 *      That is what stops `u=javascript:alert(1)` from becoming a clickable payload.
 *
 * The Content-Security-Policy in _headers is the belt to this file's braces: even if a
 * rendering bug ever injected a <script>, `script-src 'self'` would refuse to run it.
 */
(function () {
  'use strict';

  var SCHEMA_VERSION = '1';
  var CUSTOM_SCHEME = 'com.aiarcheology.ios://f';

  // Mirrors FindingShareLink.Limit in the app. A hostile link should not be able to hand the
  // page a megabyte of text in a field styled to be one line.
  var LIMITS = { t: 80, c: 60, a: 60, u: 400 };

  function show(id) {
    var element = document.getElementById(id);
    if (element) { element.hidden = false; }
  }

  function setText(id, value) {
    var element = document.getElementById(id);
    if (element) { element.textContent = value; }
  }

  /**
   * Strips control characters and the Unicode bidirectional overrides, then caps the length.
   * The overrides matter as much as the length: they render as nothing while reversing the
   * display order of everything after them, which is how a label can be made to show
   * something other than what it holds.
   */
  function clean(value, limit) {
    if (typeof value !== 'string') { return ''; }
    var stripped = '';
    for (var i = 0; i < value.length; i++) {
      var code = value.charCodeAt(i);
      var isControl = code < 0x20 || (code >= 0x7f && code <= 0x9f);
      var isBidi = code >= 0x202a && code <= 0x202e;
      var isIsolate = code >= 0x2066 && code <= 0x2069;
      if (!isControl && !isBidi && !isIsolate) { stripped += value[i]; }
    }
    stripped = stripped.trim();
    return stripped.length > limit ? stripped.slice(0, limit) : stripped;
  }

  /** Rejects duplicate keys, exactly as the app's parser does, so both render the same link. */
  function readFields(fragment) {
    var params = new URLSearchParams(fragment);
    var fields = {};
    var seen = {};
    var iterator = params.entries();
    var entry = iterator.next();
    while (!entry.done) {
      var key = entry.value[0];
      if (Object.prototype.hasOwnProperty.call(seen, key)) { return null; }
      seen[key] = true;
      fields[key] = entry.value[1];
      entry = iterator.next();
    }
    return fields;
  }

  function httpsURLOrNull(raw) {
    if (typeof raw !== 'string' || raw.length === 0 || raw.length > LIMITS.u) { return null; }
    var parsed;
    try {
      parsed = new URL(raw);
    } catch (error) {
      return null;
    }
    // Exact match, not startsWith: `javascript:` and `data:` must never reach an href, and a
    // protocol check that accepts anything beginning with "http" also accepts "https-evil:".
    if (parsed.protocol !== 'https:') { return null; }
    if (parsed.username !== '' || parsed.password !== '') { return null; }
    // Drop the query and fragment, exactly as FindingShareLink.sanitizedPage does on the way
    // out. The app already strips them, so a link arriving here with a query is hand-made —
    // and the two halves of this contract disagreeing about what a link means is how one ends
    // up rendering something the other would have refused.
    parsed.search = '';
    parsed.hash = '';
    return parsed;
  }

  function parseCoordinate(raw) {
    if (typeof raw !== 'string') { return null; }
    var parts = raw.split(',');
    if (parts.length !== 2) { return null; }
    var latitude = Number(parts[0]);
    var longitude = Number(parts[1]);
    if (!isFinite(latitude) || !isFinite(longitude)) { return null; }
    if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) { return null; }
    return { latitude: latitude, longitude: longitude };
  }

  function parseConfidence(raw) {
    if (!/^\d{1,3}$/.test(raw || '')) { return null; }
    var value = parseInt(raw, 10);
    return value >= 0 && value <= 100 ? value : null;
  }

  function render() {
    var fragment = window.location.hash.replace(/^#/, '');
    if (fragment.length === 0) { show('fallback'); return; }

    var fields = readFields(fragment);
    if (fields === null || fields.v !== SCHEMA_VERSION) { show('fallback'); return; }

    var title = clean(fields.t, LIMITS.t);
    if (title.length === 0) { show('fallback'); return; }
    setText('title', title);
    document.title = title + ' - shared from ML Browser';

    var detectionClass = clean(fields.c, LIMITS.c);
    var confidence = parseConfidence(fields.p);
    if (detectionClass.length > 0) {
      setText('detection', confidence === null ? detectionClass : detectionClass + ' · ' + confidence + '%');
      show('detection');
    }

    var author = clean(fields.a, LIMITS.a);
    if (author.length > 0) { setText('author', author); show('author-row'); }

    // Rendered exactly as it travelled. Reformatting it would apply the *viewer's* locale to a
    // date the sender chose, and the value is already day-precision only.
    if (/^\d{4}-\d{2}-\d{2}$/.test(fields.d || '')) {
      setText('date', fields.d);
      show('date-row');
    }

    var coordinate = parseCoordinate(fields.g);
    if (coordinate !== null) {
      var pretty = coordinate.latitude.toFixed(5) + ', ' + coordinate.longitude.toFixed(5);
      var link = document.getElementById('location-link');
      // Built from two numbers that have already been range-checked, so there is no
      // caller-supplied text in this URL at all.
      link.href = 'https://maps.apple.com/?ll=' + coordinate.latitude + ',' + coordinate.longitude;
      link.textContent = pretty;
      show('location-row');
    }

    var page = httpsURLOrNull(fields.u);
    if (page !== null) {
      var pageLink = document.getElementById('page-link');
      pageLink.href = page.href;
      pageLink.textContent = page.host + page.pathname;
      show('page-row');
    }

    // Handing the whole fragment to the app's own scheme, so someone who already has the app
    // but arrived here anyway is one tap from the finding rather than stuck on a web page.
    var openInApp = document.getElementById('open-in-app');
    openInApp.href = CUSTOM_SCHEME + '#' + fragment;
    openInApp.hidden = false;
  }

  render();
  // A fragment change does not reload the page, so a second link tapped from within this page
  // would otherwise show the first finding.
  window.addEventListener('hashchange', function () { window.location.reload(); });
})();
