# AI Archeology brand policy

This policy explains how to refer to AI Archeology and how independently distributed forks
should distinguish themselves from the official project and app.

## Code, models and branding

The source code and the two first-party detector models are available under Apache-2.0, as
described in the [README licence section](../README.md#licence). You may use, modify and
redistribute that licensed material, including commercially, under its licence terms. This
policy does not add conditions to that licence or require permission to fork the licensed code.

[Apache-2.0 section 6](https://www.apache.org/licenses/LICENSE-2.0) reserves brand use
while allowing customary references to the work's origin and reproduction of NOTICE. Keep the
copyright and attribution notices required by the applicable licences when rebranding a fork.

The project uses **AI Archeology** and **ML Browser** as names for its project and app. Its logo
and app icon identify the official app. This policy does not assert that these names or designs
are registered trademarks, and it does not claim exclusive rights over ordinary descriptive uses
of those words. It applies only to rights the project owner holds and does not limit uses
permitted by applicable law, including fair use, reporting, commentary or criticism.

## Referring to the project

You may use the names in plain text to identify the project accurately, link to the
[upstream repository](https://github.com/aiarcheology-com/aiarcheology), describe compatibility,
give attribution, or discuss the software. Do not imply endorsement or official status that
has not been granted.

For example, a separately named app can describe itself as “Based on AI Archeology” or
“An independent fork of ML Browser.” Place this attribution in the description or credits;
make your own app name and publisher clear. No approval is needed for these factual references.

## Distributing a fork or another app

Without separate permission from the project owner, use your own app name on the Home Screen and
in any store listing, as well as your own logo and app icon, for an independently distributed app,
including TestFlight builds. Set any build setting that determines the shipped display name to
your own name.
Do not present it as the official AI Archeology or ML Browser app, an official update, or a
project-endorsed service. A disclaimer does not by itself authorize using the project's logo
or icon as your app's identity.

Give your distribution its own bundle identifier, publisher/support details and store listing.
Identify the maintainer users should contact. Keep required upstream notices and factual origin
references; rebranding does not require removing attribution or renaming internal source
identifiers such as module and type names.
An ordinary source-code fork used for contribution is not an assertion that its maintainer
publishes the official app.

The official App Store listing is maintained by the project owner. Access to this repository
does not authorize publishing to that listing, copying its branding into another listing, or
claiming its reviews, publisher identity or endorsement. This policy does not grant access to
the project's production services or accounts.

## Artwork excluded from the source-code licence

The following artwork is excluded from the repository's Apache-2.0 grant. Apart from the limited
source-fork permission below, this policy grants no copyright licence to reuse or redistribute it:

| Artwork | Repository path |
|-|-|
| App icon images | `ios/MLBrowser/iOS/Assets/Assets.xcassets/AppIcon.appiconset/*.png` |
| App logo image | `ios/MLBrowser/iOS/Assets/Assets.xcassets/AppLogo.imageset/AppLogo.png` |
| Welcome background photograph | `ios/MLBrowser/iOS/Assets/Assets.xcassets/WelcomeBackground.imageset/WelcomeBackground.jpg` |
| Repository example screenshot | `ExampleScreenshot.jpg` |

The photographs and screenshot have copyright exclusions regardless of whether they serve as
brand identifiers. Asset-catalog `Contents.json` files are configuration, not excluded artwork.
Third-party fixtures and notices retain their own terms; see [README](../README.md#licence) and
[NOTICE](../NOTICE).

A checkout or source-code fork, including a public fork, may keep and share unmodified copies of
these files as part of the source tree for development and contribution. This limited permission
does not cover shipping them in another app build or using them in another app's store listing or
marketing materials.
Before distributing an app build or listing, replace any excluded artwork it uses with material
you may distribute, or obtain separate permission covering your intended use. Ownership
confirmation alone does not grant reuse rights, and this policy does not revoke rights already
granted under another licence.

## Permission for other brand uses

For uses beyond the factual references above, open a
[brand-use request](https://github.com/aiarcheology-com/aiarcheology/issues/new/choose) by
choosing **Open a blank issue** and titling it `Brand permission request: <proposed use>`.
Address it to the repository owner. Describe the proposed name or artwork, where it will appear,
and whether you intend to distribute an app. Permission must be explicit and cover the proposed use;
silence or acceptance of a code contribution is not brand permission. Do not include private
account details in the request.
