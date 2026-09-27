#!/bin/bash
# The headless ML Browser (AIA-0970): build it, run it on its own simulators, drive it, run scenarios.
#   scripts/headless.sh build
#   scripts/headless.sh up --state a --mock-subscription subscribed --flag isPaymentsEnabled=true
#   scripts/headless.sh exec --state a goto drawer
#   scripts/headless.sh exec --state a map                (every route and possible transition, as JSON)
#   scripts/headless.sh exec --state a --format dot map   (the same as a Graphviz graph; options go before the command)
#   scripts/headless.sh test [ios/HeadlessScenarios/<file>.json …]
#   scripts/headless.sh test --lint [<file>.json …]       (routes against the checked-in map: no build, no simulator)
#   scripts/headless.sh down|reset --state a
# See specification/HEADLESS.md.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift run --package-path Tools ProjectTool headless "$@"
