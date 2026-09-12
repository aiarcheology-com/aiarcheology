#!/usr/bin/env python3
"""Generate the WordPress-ready privacy policy from the in-app copy.

The two policies must say the same thing. They drifted once already (AIA-0624: the
technical-log wording landed in the app and never reached the hosted page), so the hosted
copy is derived here rather than maintained by hand.

    scripts/privacy_policy_hosted.py            # write docs/privacy/privacy-policy-hosted.html
    scripts/privacy_policy_hosted.py --check    # exit 1 if the output is stale

The in-app file is the source of truth. What comes out is the <body> content only: no
doctype, no <head>, no <style> -- WordPress supplies the page chrome, and pasting the app's
system-font styling into it would fight the site theme.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / "ios/MLBrowser/iOS/Documents/privacypolicy.html"
OUTPUT = REPO / "docs/privacy/privacy-policy-hosted.html"

WP_OUTPUT = REPO / "docs/privacy/privacy-policy-wordpress.html"

# Entities the in-app file uses for typography. WordPress stores these as literal characters,
# so convert them -- but leave &amp;/&lt;/&gt; alone, which must stay escaped in block markup.
TYPOGRAPHY = {
    "&rsquo;": "\u2019", "&lsquo;": "\u2018", "&ldquo;": "\u201c", "&rdquo;": "\u201d",
    "&mdash;": "\u2014", "&ndash;": "\u2013", "&rarr;": "\u2192", "&nbsp;": "\u00a0",
    "&hellip;": "\u2026",
}

TOP_LEVEL = re.compile(
    r"<h1\b[^>]*>.*?</h1>|<h2\b[^>]*>.*?</h2>|<h3\b[^>]*>.*?</h3>"
    r"|<p\b[^>]*>.*?</p>|<ul\b[^>]*>.*?</ul>|<table\b[^>]*>.*?</table>",
    re.S,
)


def _text(chunk: str) -> str:
    for entity, char in TYPOGRAPHY.items():
        chunk = chunk.replace(entity, char)
    return re.sub(r"\s+", " ", chunk).strip()


def to_blocks(body: str) -> str:
    """Render the policy body as Gutenberg block markup.

    The hosted page is a native block document, not a Custom HTML blob. Replacing it with raw
    HTML would render but would take the page out of the block editor, so the structure is
    reproduced block for block instead. Gutenberg's own `rawHandler` would do this too, but it
    times out in-browser on a document this size.
    """
    # Anything between the matches is content this converter does not know how to render. Left
    # unchecked it simply vanished from the hosted copy while --check still passed, because --check
    # compares generated to committed, not hosted to in-app. A future <ol> or <blockquote> would
    # have gone missing from the page users actually read.
    covered = 0
    for match in TOP_LEVEL.finditer(body):
        between = body[covered:match.start()].strip()
        if between:
            raise SystemExit(
                f"privacy_policy_hosted: top-level content this script cannot convert to a block:\n"
                f"  {between[:200]}\n"
                f"Add a rule for it to TOP_LEVEL and to_blocks() rather than letting it disappear."
            )
        covered = match.end()
    trailing = body[covered:].strip()
    if trailing:
        raise SystemExit(f"privacy_policy_hosted: unconverted trailing content:\n  {trailing[:200]}")

    out = []
    for match in TOP_LEVEL.finditer(body):
        chunk = match.group(0)
        tag = re.match(r"<(\w+)", chunk).group(1)
        inner = _text(re.sub(r"^<[^>]+>|</\w+>$", "", chunk))

        if tag == "h1":
            continue  # the WordPress page title already supplies the H1
        if tag in ("h2", "h3"):
            level = "" if tag == "h2" else ' {"level":3}'
            out.append(f'<!-- wp:heading{level} -->\n'
                       f'<{tag} class="wp-block-heading">{inner}</{tag}>\n'
                       f'<!-- /wp:heading -->')
        elif tag == "p":
            css = re.search(r'class="([^"]+)"', chunk)
            attrs = f' {{"className":"{css.group(1)}"}}' if css else ""
            open_tag = f'<p class="{css.group(1)}">' if css else "<p>"
            out.append(f'<!-- wp:paragraph{attrs} -->\n{open_tag}{inner}</p>\n<!-- /wp:paragraph -->')
        elif tag == "ul":
            items = []
            for li in re.finditer(r"<li\b[^>]*>(.*?)</li>", chunk, re.S):
                items.append(f'<!-- wp:list-item -->\n<li>{_text(li.group(1))}</li>\n<!-- /wp:list-item -->')
            body_items = "\n\n".join(items)
            out.append(f'<!-- wp:list -->\n<ul class="wp-block-list">{body_items}</ul>\n<!-- /wp:list -->')
        elif tag == "table":
            rows = re.findall(r"<tr\b[^>]*>(.*?)</tr>", chunk, re.S)
            head, body_rows = "", []
            for index, row in enumerate(rows):
                cells = re.findall(r"<(th|td)\b[^>]*>(.*?)</\1>", row, re.S)
                rendered = "".join(f"<{kind}>{_text(value)}</{kind}>" for kind, value in cells)
                if index == 0 and cells and cells[0][0] == "th":
                    head = f"<thead><tr>{rendered}</tr></thead>"
                else:
                    body_rows.append(f"<tr>{rendered}</tr>")
            table = f'<figure class="wp-block-table"><table>{head}<tbody>{"".join(body_rows)}</tbody></table></figure>'
            out.append(f'<!-- wp:table {{"hasFixedLayout":false}} -->\n{table}\n<!-- /wp:table -->')
    return "\n\n".join(out) + "\n"


BANNER = """<!--
  Generated from ios/MLBrowser/iOS/Documents/privacypolicy.html by
  scripts/privacy_policy_hosted.py -- do not edit this file, and do not edit the hosted
  page by hand. Change the in-app copy, regenerate, and paste the result into WordPress.
  This file is block markup, not a Custom HTML blob: pasting it into the block editor
  reproduces the page block for block. The two must always say the same thing.
-->
"""


def render(source_html: str) -> str:
    match = re.search(r"<body>(.*)</body>", source_html, re.S)
    if match is None:
        raise SystemExit(f"no <body> found in {SOURCE}")
    body = match.group(1).strip()
    return f"{BANNER}{body}\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the committed output matches the in-app copy; do not write",
    )
    args = parser.parse_args()

    source_html = SOURCE.read_text(encoding="utf-8")
    rendered = render(source_html)
    body = re.search(r"<body>(.*)</body>", source_html, re.S).group(1)
    wordpress = to_blocks(body)

    if args.check:
        if not OUTPUT.exists():
            print(f"MISSING: {OUTPUT.relative_to(REPO)} -- run scripts/privacy_policy_hosted.py")
            return 1
        if not WP_OUTPUT.exists() or WP_OUTPUT.read_text(encoding="utf-8") != wordpress:
            print(
                f"STALE: {WP_OUTPUT.relative_to(REPO)} does not match the in-app policy.\n"
                "Run scripts/privacy_policy_hosted.py and update the hosted page."
            )
            return 1
        if OUTPUT.read_text(encoding="utf-8") != rendered:
            print(
                f"STALE: {OUTPUT.relative_to(REPO)} does not match the in-app policy.\n"
                "Run scripts/privacy_policy_hosted.py and update the hosted page."
            )
            return 1
        print("Hosted privacy policy is in sync with the in-app copy.")
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered, encoding="utf-8")
    WP_OUTPUT.write_text(wordpress, encoding="utf-8")
    print(f"Wrote {OUTPUT.relative_to(REPO)} ({len(rendered)} bytes)")
    print(f"Wrote {WP_OUTPUT.relative_to(REPO)} ({len(wordpress)} bytes, Gutenberg blocks)")
    print("Paste it into the WordPress page at https://aiarcheology.com/privacy-policy/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
