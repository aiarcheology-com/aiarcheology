# link.aiarcheology.com — shared-finding links (AIA-0650)

The static site behind every finding link the app shares. Four jobs, no server:

1. Serve `apple-app-site-association` so iOS associates the domain with the app and opens
   shared links **in ML Browser** instead of Safari.
2. Show a reader who does not have the app what the finding is, and send them to the App Store.
3. Give a reader who *does* have the app a one-tap way in, for the cases where iOS did not
   route the link itself.
4. Learn nothing about anybody in the process.

## Why this is not on aiarcheology.com

`aiarcheology.com` is a **WordPress.com Simple** site (`is_wpcom_atomic: false`,
`jetpack: false`). Universal links require a file at
`/.well-known/apple-app-site-association` — extensionless, inside a dot-directory, HTTP 200,
no redirect — and that plan cannot serve one:

- plugins and SFTP need Business/Commerce, so no file can be placed at a chosen path;
- media uploads always land under `/wp-content/uploads/YYYY/MM/name.ext`, and JSON is not an
  accepted upload type;
- a page or post cannot live at a dot-path — WordPress strips the leading dot and serves a
  trailing-slash redirect, and a redirect disqualifies the file;
- `https://aiarcheology.com/.well-known/` returns **403** from Automattic's nginx, which
  reserves the path for certificate challenges. Requests never reach WordPress at all.

A subdomain costs nothing, risks nothing on the live marketing site, and keeps these files
version-controlled and reviewable. `clerk.aiarcheology.com` already works this way.

## Layout

```
web/
  README.md                                this file - deliberately OUTSIDE the upload root
  link-site/                               <- everything below here is published publicly
    .well-known/apple-app-site-association the association file; appID ZLR4X4U8UQ.com.aiarcheology.ios
    f.html                                 the landing page, served at /f
    404.html                               disables Pages' SPA fallback - see below
    app.js                                 renders the fragment; textContent only, https-only hrefs
    styles.css                             separate file because the CSP forbids inline styles
    _headers                               content type for the AASA + the security headers
    _redirects                             /f/ -> /f, / -> /f
```

**This file lives one level above `link-site/` on purpose.** Direct Upload publishes every
file in the directory it is given, so a README kept alongside the site was served at
`https://link.aiarcheology.com/README.md` with a 200 — internal deploy notes and engineering
rationale on a public domain. Anything added to `link-site/` is public; assume it will be read.

**`f.html`, not `f/index.html`.** Pages serves `/contact.html` at `/contact` and redirects the
`.html` form to it, but it redirects `/about/index.html` to `/about/` — so the directory form
would answer `/f` with a 308 to `/f/`. iOS matches a universal link against the URL *as
tapped*, before any redirect runs, so that form means the app silently never opens with no
error anywhere to tell you.

**`404.html` is load-bearing, and not for its text.** Pages' documented behaviour: *"If your
project does not include a top-level `404.html` file, Pages assumes that you are deploying a
single-page application"* and matches every unpublished path to the root document with a
**200**. Without this file, if Pages ever declined to publish the `.well-known`
dot-directory, `/.well-known/apple-app-site-association` would answer `200` with HTML — and
the `_headers` rule for that exact path would stamp `Content-Type: application/json` onto it.
The verification below would pass while iOS was being handed a document it cannot parse. With
`404.html` present the same situation returns a plain 404, which check 1 catches immediately.

## The link format

```
https://link.aiarcheology.com/f#v=1&i=<uuid>&t=<title>&c=<class>&p=<0-100>&g=<lat,lon>&u=<page>&a=<author>&d=<yyyy-mm-dd>
```

The payload is in the **fragment**, which browsers never transmit. Nothing about a finding —
its title, its author's name, its coordinates, or the page it came from — reaches this host's
request log, its cache key, or the `Referer` of any outbound click. The same data in a query
string would be uploaded on every single open. `FindingShareLink.swift` is the other half of
this contract; the two parsers agree on version, duplicate keys and the `https`-only rule for
`u`, and they must be changed together.

## Deploying

Direct Upload, not the Git integration: this repository is private and holds the whole app,
and Cloudflare has no reason to read any of it. Direct Upload sends only this directory.

```
npx wrangler pages project create aiarcheology-link
npx wrangler pages deploy web/link-site --project-name=aiarcheology-link
```

Then in the Cloudflare dashboard: the Pages project → Custom domains → add
`link.aiarcheology.com`, and copy the `<project>.pages.dev` target it shows you.

Then in WordPress.com → Domains → aiarcheology.com → DNS records:

```
Type:      CNAME
Name:      link
Points to: <project>.pages.dev
```

Redeploy with the same `wrangler pages deploy` command whenever these files change. Deploys
are deliberately manual — for a file that changes almost never, nothing should reach the live
host without someone running the command.

## Verifying (all four must pass before the feature flag is switched on)

```
curl -sSI https://link.aiarcheology.com/.well-known/apple-app-site-association
```
`200`, `content-type: application/json`, **no redirect**. A 404 means Cloudflare Pages did not
publish the dot-directory; if that happens, move the file to `well-known/…` and add a
`/.well-known/apple-app-site-association  /well-known/apple-app-site-association  200` rewrite
to `_redirects`.

```
curl -sS https://link.aiarcheology.com/.well-known/apple-app-site-association | python3 -m json.tool
```
`appIDs` contains `ZLR4X4U8UQ.com.aiarcheology.ios` and `components` contains `/f`.

```
curl -sSI https://link.aiarcheology.com/f
```
`200`, **not** a `308` to `/f/`. A redirect here means universal links never open the app.

```
curl -sS https://app-site-association.cdn-apple.com/a/v1/link.aiarcheology.com | python3 -m json.tool
```
Apple's CDN copy — this is what devices actually fetch, and it can lag a deploy considerably.

On a device running a build that contains `applinks:link.aiarcheology.com`:
Settings → Developer → Universal Links → Diagnostics.

Only when all of these pass, set the ConfigCat flag `isFindingShareLinkEnabled` to `true`.
Turning it on earlier produces links that open Safari on a domain that is not answering.

## Security posture

Every value rendered here arrives from a stranger's URL, so two rules hold absolutely in
`app.js`: text reaches the document **only** through `textContent`, and a URL becomes an
`href` **only** after `new URL()` parses it and its protocol is exactly `https:`. The
Content-Security-Policy in `_headers` is the second lock — `script-src 'self'` means an
injected `<script>` cannot run even if a rendering bug ever emitted one.

The page also asserts, in its own copy, that the finding was written by whoever shared it and
has not been verified. Associated Domains authenticates the **domain**; it says nothing about
the parameters, all of which anyone can forge.

## Not done here

The page is English only. It is the pre-install surface for a link that already carries its
own text, so it is deliberately outside the app's localization gate
(`Localizable.xcstrings`); if that changes, it needs its own strategy rather than being bolted
onto the app catalog.
