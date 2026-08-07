#!/usr/bin/env python3
"""
xcstrings_tool.py — inspect, translate-merge and validate the app String Catalog.

Why this exists (AIA-0572)
--------------------------
`Localizable.xcstrings` is a 16k-line JSON document that Xcode owns. Re-serialising it with
`json.dump` reformats every line and re-sorts keys, producing an unreviewable diff — the trap
documented in the ship-ticket localization reference.

Two properties of the real file make a naive round-trip *impossible* to do byte-faithfully:

  1. Top-level key order follows ICU root collation, not ASCII: `"/ %@"` sorts before `"%.2f"`.
     Reproducing that needs ICU, which the stdlib does not provide.
  2. Escaping is not uniform. Two `comment` values carry a literal `\\u2014` escape while every
     other em dash in the file is a raw UTF-8 character. No single escaping rule reproduces both.

So this tool never rewrites the document. It *splices*: a string-aware scanner locates the exact
byte span of each locale block, and edits are applied only inside those spans. Every byte outside
an edited span is preserved by construction, which is a stronger guarantee than "the round-trip
happened to match".

Subcommands
-----------
  check    Prove the splicer is a no-op: apply zero edits, assert the output is byte-identical.
  report   Per-locale coverage. Counts a value identical to English as *untranslated*.
  merge    Insert translations from a directory of <locale>.json files.
  verify   Gate the catalog: locale parity, format-specifier agreement, plural-category sanity.

`verify` is the safety net that `check` cannot provide: `check` only exercises formatting that
already exists in the file, so it says nothing about newly written content. `verify` re-parses the
result and validates semantics.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "ios/MLBrowser/iOS/Resources/Localizable.xcstrings"

SOURCE_LANGUAGE = "en"

# The 16 translation targets, in the casefold order Xcode writes `localizations` — note
# zh-Hans/zh-Hant precede zh-HK ("hans" < "hant" < "hk"), which is NOT ASCII order.
#
# This order is load-bearing, not cosmetic. When a key gains several locales at once they all
# resolve to the same insertion anchor, so the order they are generated in becomes the order they
# appear in the file. Listing zh-HK first here put it before zh-Hans in 250 keys.
TARGET_LOCALES = [
    "ar", "bn", "cs", "de", "es", "fa", "fr", "he",
    "hi", "hu", "pl", "ru", "uk", "zh-Hans", "zh-Hant", "zh-HK",
]

# CLDR plural categories each locale REQUIRES. A missing category silently falls back to `other`,
# which is a grammar bug in Slavic and Arabic ("5 položka" instead of "5 položek"), so absence is a
# hard failure.
#
# Supersets are NOT failures. `zero` is Apple's exact-match special case and is legal in every
# language regardless of CLDR (the catalog already uses it for "No items"), and a redundant `one`
# in Chinese is dead weight but harmless. Rejecting supersets would flag the catalog's own existing
# correct data and could push a translator into deleting a live `zero` special case.
REQUIRED_PLURAL_CATEGORIES = {
    "ar": {"zero", "one", "two", "few", "many", "other"},
    "bn": {"one", "other"},
    "cs": {"one", "few", "many", "other"},
    "de": {"one", "other"},
    "en": {"one", "other"},
    "es": {"one", "many", "other"},
    "fa": {"one", "other"},
    "fr": {"one", "many", "other"},
    "he": {"one", "two", "many", "other"},
    "hi": {"one", "other"},
    "hu": {"one", "other"},
    "pl": {"one", "few", "many", "other"},
    "ru": {"one", "few", "many", "other"},
    "uk": {"one", "few", "many", "other"},
    "zh-HK": {"other"},
    "zh-Hans": {"other"},
    "zh-Hant": {"other"},
}

# Apple's exact-match special case, legal in any language.
ALWAYS_ALLOWED_CATEGORIES = {"zero"}

# Proper nouns, brand names and file extensions that must survive translation verbatim. Restricted
# to unambiguous tokens — ordinary words that happen to be technical ("Vision", "URL") are excluded
# because they legitimately translate.
DO_NOT_TRANSLATE = [
    "AI Archeology", "ML Browser", "Core ML", "Create ML", "Hugging Face", "TestFlight",
    "App Store", "ONNX", ".mlmodel", ".mlpackage", ".onnx", "iCloud", "Face ID", "Touch ID",
]

# Legal, billing and irreversible-action copy. Machine translation is NOT applied here: a wrong
# auto-renewal disclosure risks an App Review 3.1.2 rejection in de/cs/pl/hu (all jurisdictions with
# statutory auto-renew disclosure rules), and a wrong account-deletion confirmation can cause an
# irreversible user action in a language nobody on the team reads. These keys keep falling back to
# English, exactly as they do today, until a human translator pass covers them.
NO_MACHINE_TRANSLATION_PREFIXES = (
    "paywall.", "subscription.", "auth.account.delete.", "settings.subscription.",
)

# `%@`, `%lld`, `%1$@`, `%.2f`, `%%` … Captures the positional index so ordering can be compared,
# and the length modifier, because `%d` and `%lld` consume different argument widths — treating
# them as interchangeable would let a translation silently misread its argument.
FORMAT_SPEC = re.compile(
    r"%(?:(\d+)\$)?[-+ #0]*[\d.*]*((?:hh|h|ll|l|q|z|t|j|L)?)([@diouxXeEfgGcsSpaAn%])")


# --------------------------------------------------------------------------------------------
# String-aware scanner
# --------------------------------------------------------------------------------------------

def _skip_ws(text: str, i: int) -> int:
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    return i


def _scan_string(text: str, i: int) -> int:
    """`i` points at the opening quote. Returns the index just past the closing quote."""
    assert text[i] == '"', f"expected string at {i}, found {text[i]!r}"
    i += 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2  # skip the escape *and* the escaped char, so \\" does not end the string
            continue
        if c == '"':
            return i + 1
        i += 1
    raise ValueError("unterminated string")


def _scan_value(text: str, i: int) -> int:
    """Returns the index just past the value beginning at `i`. Handles nesting and strings."""
    i = _skip_ws(text, i)
    c = text[i]
    if c == '"':
        return _scan_string(text, i)
    if c in "{[":
        close = "}" if c == "{" else "]"
        depth = 0
        while i < len(text):
            ch = text[i]
            if ch == '"':
                i = _scan_string(text, i)
                continue
            if ch in "{[":
                depth += 1
            elif ch in "}]":
                depth -= 1
                if depth == 0:
                    assert ch == close, f"bracket mismatch at {i}"
                    return i + 1
            i += 1
        raise ValueError("unterminated container")
    # primitive: number / true / false / null
    j = i
    while j < len(text) and text[j] not in ",}]\r\n \t":
        j += 1
    return j


def object_members(text: str, obj_start: int) -> tuple[list[dict], int]:
    """
    Parse the immediate members of the JSON object whose `{` sits at `obj_start`.

    Returns (members, index_just_past_closing_brace) where each member is a dict with the decoded
    `key` and the byte spans needed for splicing:
      member_start — first char of the `"key"` token
      value_start / value_end — span of the member's value
      member_end   — end of the value (comma excluded)
    """
    assert text[obj_start] == "{", f"expected {{ at {obj_start}, found {text[obj_start]!r}"
    i = obj_start + 1
    members: list[dict] = []
    while True:
        i = _skip_ws(text, i)
        if text[i] == "}":
            return members, i + 1
        if text[i] == ",":
            i += 1
            continue
        key_start = i
        key_end = _scan_string(text, i)
        key = json.loads(text[key_start:key_end])
        i = _skip_ws(text, key_end)
        assert text[i] == ":", f"expected : at {i}"
        i = _skip_ws(text, i + 1)
        value_start = i
        value_end = _scan_value(text, i)
        members.append({
            "key": key,
            "member_start": key_start,
            "value_start": value_start,
            "value_end": value_end,
            "member_end": value_end,
        })
        i = value_end


def find_member(members: list[dict], key: str) -> dict | None:
    for m in members:
        if m["key"] == key:
            return m
    return None


def catalog_spans(text: str) -> dict[str, dict]:
    """Map every top-level string key to its entry span and its `localizations` span."""
    root, _ = object_members(text, _skip_ws(text, 0))
    strings = find_member(root, "strings")
    assert strings, "catalog has no top-level `strings` object"
    entries, _ = object_members(text, strings["value_start"])

    out: dict[str, dict] = {}
    for entry in entries:
        entry_members, _ = object_members(text, entry["value_start"])
        loc = find_member(entry_members, "localizations")
        info = {"entry": entry, "localizations": loc, "locales": {}}
        if loc:
            locale_members, _ = object_members(text, loc["value_start"])
            info["locales"] = {m["key"]: m for m in locale_members}
            info["locale_order"] = [m["key"] for m in locale_members]
        out[entry["key"]] = info
    return out


# --------------------------------------------------------------------------------------------
# Xcode-style rendering (only ever used for NEW content)
# --------------------------------------------------------------------------------------------

def render(value, indent: int) -> str:
    """
    Render `value` the way Xcode writes String Catalog JSON: 2-space indent, `" : "` separator,
    members in casefold order, raw non-ASCII. Verified against the real catalog at every nesting
    level (entry members, stringUnit, variations, plural categories are all casefold-ordered).
    """
    pad = " " * indent
    if isinstance(value, dict):
        if not value:
            # Xcode renders an empty object as `{`, a blank line, then the closing brace.
            return "{\n\n" + pad + "}"
        inner = " " * (indent + 2)
        parts = [
            f"{inner}{json.dumps(k, ensure_ascii=False)} : {render(v, indent + 2)}"
            for k, v in sorted(value.items(), key=lambda kv: kv[0].casefold())
        ]
        return "{\n" + ",\n".join(parts) + "\n" + pad + "}"
    if isinstance(value, list):
        inner = " " * (indent + 2)
        parts = [f"{inner}{render(v, indent + 2)}" for v in value]
        return "[\n" + ",\n".join(parts) + "\n" + pad + "]"
    return json.dumps(value, ensure_ascii=False)


def string_unit(value: str, state: str = "needs_review") -> dict:
    return {"stringUnit": {"state": state, "value": value}}


def plural_unit(by_category: dict[str, str], state: str = "needs_review") -> dict:
    return {"variations": {"plural": {
        cat: {"stringUnit": {"state": state, "value": v}} for cat, v in by_category.items()
    }}}


def device_unit(by_device: dict[str, str], state: str = "needs_review") -> dict:
    return {"variations": {"device": {
        dev: {"stringUnit": {"state": state, "value": v}} for dev, v in by_device.items()
    }}}


# --------------------------------------------------------------------------------------------
# Splicing
# --------------------------------------------------------------------------------------------

def apply_edits(text: str, edits: list[tuple[int, int, str]]) -> str:
    """
    Apply (start, end, replacement) splices right-to-left so earlier offsets stay valid.

    Several insertions routinely share one anchor: when a key has only `en`, every locale sorting
    before it (ar, bn, cs, de) is computed against the same original text and lands at the same
    offset. Applying at a shared anchor pushes whatever is already there to the right, so the FIRST
    applied ends up LAST. Ties must therefore be applied in reverse of their intended order —
    sorting by start alone leaves them reversed in the file.
    """
    for start, end, _ in edits:
        assert start <= end, f"bad span {start}..{end}"
    # Sort by (start, sequence) descending: among equal anchors the last-generated edit is applied
    # first and so ends up rightmost, preserving generation order in the output.
    ordered = [e for _, e in sorted(enumerate(edits), key=lambda ie: (ie[1][0], ie[0]), reverse=True)]
    for a, b in zip(ordered, ordered[1:]):
        assert b[1] <= a[0], f"overlapping edits: {b[0]}..{b[1]} and {a[0]}..{a[1]}"
    out = text
    for start, end, replacement in ordered:
        out = out[:start] + replacement + out[end:]
    return out


def upsert_locale(text: str, spans: dict, key: str, locale: str, block: dict) -> tuple[int, int, str]:
    """
    Build the splice that inserts (or replaces) `locale` inside `key`'s `localizations` object.

    Insertion position follows Xcode's casefold ordering of locale codes, verified against the
    112 fully-populated keys in the real catalog.
    """
    info = spans[key]
    loc_member = info["localizations"]
    if loc_member is None:
        raise ValueError(f"key {key!r} has no `localizations` object; cannot add {locale}")

    rendered = render(block, 8)
    existing = info["locales"]

    if locale in existing:
        m = existing[locale]
        return (m["value_start"], m["value_end"], rendered)

    order = info["locale_order"]
    after = None
    for code in order:
        if code.casefold() < locale.casefold():
            after = code
        else:
            break

    entry_text = f'{json.dumps(locale, ensure_ascii=False)} : {rendered}'
    if after is None:
        # Becomes the first member: insert right after the opening brace.
        anchor = loc_member["value_start"] + 1
        return (anchor, anchor, "\n" + " " * 8 + entry_text + ",")
    m = existing[after]
    anchor = m["value_end"]
    return (anchor, anchor, ",\n" + " " * 8 + entry_text)


# --------------------------------------------------------------------------------------------
# Analysis helpers
# --------------------------------------------------------------------------------------------

def load_catalog(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def translatable_keys(cat: dict) -> list[str]:
    """Keys a translator can act on: authored via the catalog editor and carrying an English source."""
    return [
        k for k, v in cat["strings"].items()
        if v.get("extractionState") == "manual" and (v.get("localizations") or {}).get(SOURCE_LANGUAGE)
    ]


def flatten(loc: dict | None) -> dict[str, str] | None:
    """Reduce a localization block to {variant: value} so blocks can be compared uniformly."""
    if not loc:
        return None
    if "stringUnit" in loc:
        return {"": loc["stringUnit"]["value"]}
    variations = loc.get("variations") or {}
    for kind in ("plural", "device"):
        if kind in variations:
            return {c: u["stringUnit"]["value"] for c, u in variations[kind].items()}
    return None


def specifiers(value: str) -> list[str]:
    """
    Normalised format specifiers in argument order.

    Ordered by positional index when the string uses `%n$` form, otherwise by appearance — which is
    exactly the order `String(format:)` consumes arguments, so two lists being equal means the two
    strings consume the same arguments in the same order.
    """
    found = [(m.group(1), m.group(2), m.group(3)) for m in FORMAT_SPEC.finditer(value)]
    found = [f for f in found if f[2] != "%"]  # %% is a literal percent, not an argument
    if any(pos for pos, _, _ in found):
        found.sort(key=lambda f: int(f[0]) if f[0] else 0)
    return [f"%{length}{conv}" for _, length, conv in found]


def is_submultiset(small: list[str], big: list[str]) -> bool:
    from collections import Counter
    c_small, c_big = Counter(small), Counter(big)
    return all(c_big[k] >= v for k, v in c_small.items())


# --------------------------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------------------------

def cmd_check(args) -> int:
    """Prove the splicer is byte-neutral when it applies no edits."""
    text = CATALOG.read_text(encoding="utf-8")
    spans = catalog_spans(text)
    rebuilt = apply_edits(text, [])
    ok = rebuilt == text

    parsed = json.loads(text)
    keys_scanned = set(spans)
    keys_parsed = set(parsed["strings"])
    same_keys = keys_scanned == keys_parsed

    print(f"scanner found {len(keys_scanned)} keys; json.load found {len(keys_parsed)}")
    print(f"key sets identical .......... {'PASS' if same_keys else 'FAIL'}")
    print(f"zero-edit splice is a no-op .. {'PASS' if ok else 'FAIL'}")

    # Re-render every existing locale block and compare to the bytes actually in the file. This is
    # the real test of `render()`: it proves the renderer agrees with Xcode on content it did not
    # write, which is what makes it trustworthy for content it does write.
    mismatches = []
    for key, info in spans.items():
        for locale, member in info["locales"].items():
            original = text[member["value_start"]:member["value_end"]]
            block = json.loads(original)
            if render(block, 8) != original:
                mismatches.append((key, locale))
    print(f"render() reproduces {sum(len(i['locales']) for i in spans.values())} existing locale "
          f"blocks .. {'PASS' if not mismatches else f'FAIL ({len(mismatches)})'}")
    for key, locale in mismatches[:5]:
        print(f"    mismatch: {key} / {locale}")

    # Reproducing existing blocks proves nothing about escaping: the real catalog contains no
    # backslash, no escaped quote and no control character, so every escape branch of render() is
    # unreached above and live during `merge`. Exercise them synthetically instead.
    hostile = [
        'straight "quotes" inside',
        "back\\slash and \\\\ double",
        "em dash — and ellipsis …",
        "emoji 🎉 and CJK 中文 and Devanagari अनुवाद",
        "RTL نص عربي mixed with latin",
        "tab\there",
        "unicode line sep   and para sep  ",
        "percent %% literal and %1$@ positional",
        " non-breaking space",
    ]
    escape_failures = []
    for value in hostile:
        block = string_unit(value, "needs_review")
        rendered = render(block, 8)
        try:
            if json.loads(rendered) != block:
                escape_failures.append((value, "round-trip changed the value"))
        except json.JSONDecodeError as exc:
            escape_failures.append((value, f"produced invalid JSON: {exc}"))
    print(f"render() survives {len(hostile)} hostile escaping cases .. "
          f"{'PASS' if not escape_failures else f'FAIL ({len(escape_failures)})'}")
    for value, why in escape_failures[:5]:
        print(f"    {value!r}: {why}")

    # And the same for a full splice into a real key, proving an edited document still parses.
    probe_key = next(k for k, i in spans.items() if i["localizations"] and "cs" not in i["locales"])
    probe = apply_edits(text, [upsert_locale(
        text, spans, probe_key, "cs", string_unit('spliced "value" — 中文 🎉', "needs_review"))])
    try:
        reparsed = json.loads(probe)
        spliced_ok = (reparsed["strings"][probe_key]["localizations"]["cs"]["stringUnit"]["value"]
                      == 'spliced "value" — 中文 🎉'
                      and set(reparsed["strings"]) == keys_parsed)
    except Exception as exc:  # noqa: BLE001 - report any failure shape
        spliced_ok = False
        print(f"    splice probe raised: {exc}")
    print(f"splice into {probe_key!r} reparses correctly .. {'PASS' if spliced_ok else 'FAIL'}")

    # Regression test for anchor-tie ordering. Inserting several locales into a key that has only
    # `en` makes them all resolve to the same offset; a naive right-to-left application reverses
    # them, and the next Xcode catalog-editor save would then re-sort hundreds of keys.
    tie_key = next((k for k, i in spans.items()
                    if i["localizations"] and set(i["locales"]) == {"en"}), None)
    if tie_key is None:
        print("locale insertion order .. SKIP (no en-only key to probe)")
        order_ok = True
    else:
        # Use the real TARGET_LOCALES list, in the real order `merge` iterates it — a hand-picked
        # probe list would silently vindicate a mis-ordered constant.
        tie_edits = [upsert_locale(text, spans, tie_key, loc, string_unit(f"v-{loc}"))
                     for loc in TARGET_LOCALES]
        tied = json.loads(apply_edits(text, tie_edits))
        got = list(tied["strings"][tie_key]["localizations"])
        want = sorted(got, key=str.casefold)
        order_ok = got == want
        print(f"locale insertion order preserved .. {'PASS' if order_ok else 'FAIL'}")
        if not order_ok:
            print(f"    got  {got}\n    want {want}")

    return 0 if (ok and same_keys and not mismatches and not escape_failures
                 and spliced_ok and order_ok) else 1


def cmd_report(args) -> int:
    cat = load_catalog(CATALOG)
    keys = translatable_keys(cat)
    total = len(keys)
    print(f"Catalog: {CATALOG.relative_to(REPO_ROOT)}")
    print(f"  {len(cat['strings'])} keys total, {total} translatable "
          f"(extractionState=manual with an `{SOURCE_LANGUAGE}` source)\n")
    print(f"  {'locale':9} {'present':>8} {'missing':>8} {'=EN':>5} {'translated':>11} {'coverage':>9}")
    worst = 1.0
    for locale in TARGET_LOCALES:
        present = missing = same = 0
        for k in keys:
            locs = cat["strings"][k]["localizations"]
            block = flatten(locs.get(locale))
            if block is None:
                missing += 1
                continue
            present += 1
            if block == flatten(locs.get(SOURCE_LANGUAGE)):
                same += 1
        real = present - same
        cov = real / total if total else 0.0
        worst = min(worst, cov)
        print(f"  {locale:9} {present:8} {missing:8} {same:5} {real:11} {cov:8.1%}")
    print(f"\n  worst locale coverage: {worst:.1%}")
    return 0


def cmd_merge(args) -> int:
    src = Path(args.source)
    text = CATALOG.read_text(encoding="utf-8")
    spans = catalog_spans(text)
    cat = json.loads(text)

    edits: list[tuple[int, int, str]] = []
    stats: dict[str, int] = {}
    skipped = 0
    for locale in TARGET_LOCALES:
        f = src / f"{locale}.json"
        if not f.exists():
            print(f"  {locale}: no file, skipped")
            continue
        payload = json.loads(f.read_text(encoding="utf-8"))
        n = 0
        for key, value in payload.items():
            if key not in spans:
                raise SystemExit(f"{locale}.json references unknown key {key!r}")
            en = cat["strings"][key]["localizations"][SOURCE_LANGUAGE]
            if isinstance(value, str):
                block = string_unit(value, args.state)
            elif isinstance(value, dict) and "plural" in value:
                block = plural_unit(value["plural"], args.state)
            elif isinstance(value, dict) and "device" in value:
                block = device_unit(value["device"], args.state)
            else:
                raise SystemExit(f"{locale}.json key {key!r}: unrecognised shape {type(value)}")
            # A translation must not change the *shape* of the entry.
            if ("variations" in en) != ("variations" in block):
                raise SystemExit(
                    f"{locale}.json key {key!r}: shape mismatch — English "
                    f"{'has' if 'variations' in en else 'has no'} variations but translation "
                    f"{'has' if 'variations' in block else 'has none'}")

            # If the translation reproduces what is already there, write nothing. Rewriting it
            # would keep the same text but stamp `needs_review` over an existing `translated`
            # state — downgrading metadata on strings that were already correct, and padding the
            # diff. This matters for the many short strings a locale legitimately shares with
            # English ("OK", "URL", "Web", "Error").
            existing = (cat["strings"][key]["localizations"] or {}).get(locale)
            if existing is not None and flatten(existing) == flatten(block):
                skipped += 1
                continue

            edits.append(upsert_locale(text, spans, key, locale, block))
            n += 1
        stats[locale] = n
        print(f"  {locale}: {n} blocks")

    merged = apply_edits(text, edits)
    json.loads(merged)  # fail loudly rather than write a corrupt catalog
    CATALOG.write_text(merged, encoding="utf-8")
    print(f"\nmerged {sum(stats.values())} blocks into {CATALOG.relative_to(REPO_ROOT)}"
          f"; left {skipped} unchanged block(s) untouched")
    return 0


def variation_kind(loc: dict | None) -> str | None:
    """`simple` | `plural` | `device` — the structural shape of a localization block."""
    if not loc:
        return None
    if "stringUnit" in loc:
        return "simple"
    variations = loc.get("variations") or {}
    for kind in ("plural", "device"):
        if kind in variations:
            return kind
    return None


def is_machine_translatable(key: str) -> bool:
    return not key.startswith(NO_MACHINE_TRANSLATION_PREFIXES)


def cmd_verify(args) -> int:
    cat = load_catalog(CATALOG)
    keys = translatable_keys(cat)
    problems: list[str] = []
    notes: list[str] = []

    for key in keys:
        locs = cat["strings"][key]["localizations"]
        en_loc = locs.get(SOURCE_LANGUAGE)
        en = flatten(en_loc)
        if en is None:
            problems.append(f"{key}: English source is neither a stringUnit nor a variation")
            continue
        en_kind = variation_kind(en_loc)
        en_other = en.get("other", en.get("", next(iter(en.values()))))
        en_other_specs = specifiers(en_other)

        for locale in TARGET_LOCALES:
            loc = locs.get(locale)
            block = flatten(loc)
            if block is None:
                if args.strict_parity:
                    problems.append(f"{key}: missing `{locale}`")
                continue

            # A translation must never change the entry's shape: emitting a plural block where
            # English uses `variations.device` corrupts the entry.
            kind = variation_kind(loc)
            if kind != en_kind:
                problems.append(
                    f"{key} [{locale}]: shape is `{kind}` but English is `{en_kind}`")
                continue

            if kind == "device" and set(block) != set(en):
                problems.append(
                    f"{key} [{locale}]: device variants {sorted(block)} != English {sorted(en)}")

            for variant, value in block.items():
                got = specifiers(value)

                # Mixing positional (%1$@) and bare (%@) specifiers in one string is undefined in
                # CFString and can crash.
                raw = [m for m in FORMAT_SPEC.finditer(value) if m.group(3) != "%"]
                positional = [bool(m.group(1)) for m in raw]
                if any(positional) and not all(positional):
                    problems.append(
                        f"{key} [{locale}/{variant}]: mixes positional and non-positional specifiers")

                # If English is positional, the translation must be too — otherwise reordering the
                # sentence silently swaps the arguments.
                en_variant = en.get(variant)
                if en_variant is not None:
                    en_raw = [m for m in FORMAT_SPEC.finditer(en_variant) if m.group(3) != "%"]
                    if any(m.group(1) for m in en_raw) and not all(m.group(1) for m in raw):
                        problems.append(
                            f"{key} [{locale}/{variant}]: English uses positional specifiers but "
                            f"the translation does not — argument order is not preserved")
                    want = specifiers(en_variant)
                    if got != want:
                        problems.append(
                            f"{key} [{locale}/{variant}]: specifiers {got} != English {want}")
                elif not is_submultiset(got, en_other_specs):
                    # A category English does not have (e.g. Czech `few`). It may use fewer
                    # arguments than the general form, never more.
                    problems.append(
                        f"{key} [{locale}/{variant}]: specifiers {got} exceed English "
                        f"`other` {en_other_specs}")

                # Brand names and file extensions should survive verbatim. Reported, not enforced:
                # some locales legitimately localise a product name, and several pre-existing
                # translations predate an English rewrite. A hard gate here would fail on the
                # catalog's own history rather than on new work.
                for token in DO_NOT_TRANSLATE:
                    if token in en_other and token not in value:
                        notes.append(
                            f"{key} [{locale}/{variant}]: protected term {token!r} absent")

            if kind == "plural":
                used = set(block)
                required = REQUIRED_PLURAL_CATEGORIES.get(locale, {"other"})
                if "other" not in used:
                    problems.append(f"{key} [{locale}]: plural block lacks the required `other`")
                if missing := required - used:
                    problems.append(
                        f"{key} [{locale}]: plural categories {sorted(missing)} are required by "
                        f"CLDR for this locale but absent — those counts fall back to `other`")
                if extra := used - required - ALWAYS_ALLOWED_CATEGORIES:
                    notes.append(
                        f"{key} [{locale}]: plural categories {sorted(extra)} can never match in "
                        f"this locale (harmless, but dead)")

    for n in notes[:args.limit]:
        print(f"  note: {n}")
    if problems:
        print(f"FAIL — {len(problems)} problem(s):")
        for p in problems[:args.limit]:
            print(f"  {p}")
        if len(problems) > args.limit:
            print(f"  … and {len(problems) - args.limit} more")
        return 1
    scope = "parity, " if args.strict_parity else ""
    print(f"PASS — {len(keys)} translatable keys x {len(TARGET_LOCALES)} locales verified "
          f"({scope}shape, format specifiers, plural categories, protected terms)")
    return 0


def cmd_export(args) -> int:
    """Write one worklist per locale: what to translate, with the context a translator needs."""
    cat = load_catalog(CATALOG)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    keys = translatable_keys(cat)

    skipped_legal = 0
    written = {}
    for locale in TARGET_LOCALES:
        items = []
        for key in keys:
            if not is_machine_translatable(key):
                skipped_legal += 1
                continue
            locs = cat["strings"][key]["localizations"]
            en_loc = locs[SOURCE_LANGUAGE]
            en = flatten(en_loc)
            current = flatten(locs.get(locale))
            # Needs work when absent, or when it is still a verbatim copy of the English source.
            if current is not None and current != en:
                continue
            kind = variation_kind(en_loc)
            item = {
                "key": key,
                "shape": kind,
                "english": en if kind != "simple" else en[""],
                "reason": "missing" if current is None else "untranslated (identical to English)",
            }
            if comment := cat["strings"][key].get("comment"):
                item["comment"] = comment
            if kind == "plural":
                required = set(REQUIRED_PLURAL_CATEGORIES.get(locale, {"other"}))
                # If English carries an explicit `zero` (Apple's exact-match special case, e.g.
                # "No items"), the translation must carry one too. Omitting it silently drops a
                # deliberate string and falls back to the counted form ("0 items").
                if "zero" in en:
                    required.add("zero")
                item["required_categories"] = sorted(required)
            if kind == "device":
                item["device_variants"] = sorted(en)
            items.append(item)
        payload = {
            "locale": locale,
            "instructions": (
                "Translate `english` into this locale. Preserve every format specifier "
                "(%@, %lld, %1$@ …) exactly — same count, same kind, same positional indices. "
                "Keep protected terms verbatim. Keep UI strings short; German and Russian expand. "
                "For shape=plural emit every category in required_categories. "
                "For shape=device emit exactly the device_variants keys."
            ),
            "protected_terms": DO_NOT_TRANSLATE,
            "count": len(items),
            "items": items,
        }
        (out / f"{locale}.source.json").write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        written[locale] = len(items)

    for locale, n in written.items():
        print(f"  {locale:9} {n:4} keys to translate")
    print(f"\nwrote {len(written)} worklists to {out}")
    print(f"excluded from machine translation: {skipped_legal // len(TARGET_LOCALES)} legal/billing/"
          f"destructive keys per locale (prefixes: {', '.join(NO_MACHINE_TRANSLATION_PREFIXES)})")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("check", help="prove the splicer and renderer are byte-faithful")
    sub.add_parser("report", help="per-locale coverage")

    e = sub.add_parser("export", help="write per-locale translation worklists")
    e.add_argument("--out", required=True, help="output directory")

    m = sub.add_parser("merge", help="merge <locale>.json translation files into the catalog")
    m.add_argument("--source", required=True, help="directory of <locale>.json files")
    m.add_argument("--state", default="needs_review",
                   help="stringUnit state to write (default: needs_review)")

    v = sub.add_parser("verify", help="gate shape, format specifiers and plural categories")
    v.add_argument("--strict-parity", action="store_true",
                   help="also fail when a locale is absent (completeness, not correctness)")
    v.add_argument("--limit", type=int, default=40, help="max problems to print")

    args = p.parse_args()
    return {
        "check": cmd_check, "report": cmd_report, "export": cmd_export,
        "merge": cmd_merge, "verify": cmd_verify,
    }[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
