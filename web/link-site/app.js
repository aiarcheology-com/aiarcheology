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
  //
  // `u` grew to 600 with AIA-0657, when the address stopped being reduced to its host: a map
  // viewer keeps the view in the query string, and those are frequently longer than the path.
  var LIMITS = { t: 80, c: 60, a: 60, u: 600 };

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
    // `URLSearchParams` decodes a raw `+` as a space; Foundation does not, so the same link would
    // render "a b" here and "a+b" in the app. The app escapes `+` on emission, so this only bites
    // hand-made links — but "only hand-made links" is precisely the input worth agreeing about.
    var params = new URLSearchParams(fragment.replace(/\+/g, '%2B'));
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
    // The query and fragment are KEPT, as of AIA-0657.
    //
    // They used to be stripped here, described as matching what the app did on the way out. That
    // stopped being true the moment the app began carrying them, and this half mattered more than
    // it looks: a recipient WITHOUT the app is exactly who lands on this page, and stripping here
    // would send the audience the sharing feature exists to reach to a geoportal's front door
    // while the app's own users got the view. The two halves of a contract disagreeing about what
    // a link means is how one ends up rendering something the other would have refused.
    //
    // No credential denylist here, deliberately. That belongs on the emit path, where the sender's
    // own address is, and it lives in exactly one implementation (FindingShareLink) rather than
    // being copied into a second one with no tests to keep it honest. A query that reaches this
    // page is already public - it is in a link someone posted - and rewriting it would only mean
    // the address shown is not the address opened.
    return parsed;
  }

  /**
   * A plain decimal number, and nothing else.
   *
   * `Number()` is unusable here: it accepts hex (`0x10` → 16), exponents (`1e1` → 10), leading and
   * trailing whitespace, and — worst of all — the empty string, which it turns into 0. So `g=,`
   * would have put a pin on Null Island while the Swift parser dropped the coordinate entirely.
   * The regex is the contract; `Number` only runs once the shape is already known to be decimal.
   */
  function decimal(raw) {
    if (typeof raw !== 'string' || !/^-?\d+(\.\d+)?$/.test(raw)) { return null; }
    var value = Number(raw);
    return isFinite(value) ? value : null;
  }

  function parseCoordinate(raw) {
    if (typeof raw !== 'string') { return null; }
    var parts = raw.split(',');
    if (parts.length !== 2) { return null; }
    var latitude = decimal(parts[0]);
    var longitude = decimal(parts[1]);
    if (latitude === null || longitude === null) { return null; }
    if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) { return null; }
    return { latitude: latitude, longitude: longitude };
  }

  function parseConfidence(raw) {
    if (!/^\d{1,3}$/.test(raw || '')) { return null; }
    var value = parseInt(raw, 10);
    return value >= 0 && value <= 100 ? value : null;
  }

  /**
   * `yyyy-mm-dd`, and only if the date exists.
   *
   * A regex alone accepts 2026-99-99 and 2026-02-30, which the Swift parser rejects by round-tripping
   * through a calendar. Same check here, via UTC `Date`: construct it, then read the fields back and
   * require them to match — JavaScript silently rolls 2026-02-30 forward to 2026-03-02 otherwise.
   */
  function validDate(raw) {
    if (typeof raw !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(raw)) { return null; }
    var parts = raw.split('-');
    var year = Number(parts[0]);
    var month = Number(parts[1]);
    var day = Number(parts[2]);
    var date = new Date(Date.UTC(year, month - 1, day));
    if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) {
      return null;
    }
    return raw;
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
    var date = validDate(fields.d);
    if (date !== null) {
      setText('date', date);
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
