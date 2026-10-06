#!/usr/bin/env bash
# Runs the package tests on the newest available iPhone simulator.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
device="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted((r for r in devices if "iOS" in r), reverse=True):
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit()
sys.exit("no iPhone simulator available")
')"
scheme="$(xcodebuild -list -json | python3 -c '
import json, sys
schemes = json.load(sys.stdin)["workspace"]["schemes"]
print("TailnetSession-Package" if "TailnetSession-Package" in schemes else "TailnetSession")
')"
xcodebuild test -scheme "${scheme}" -destination "id=${device}"
