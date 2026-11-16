#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/checks
swiftc Sources/EdgeControl/TrackpadMonitor.swift Tests/TrackpadPalmChecks.swift -o build/checks/trackpad-palm-checks
build/checks/trackpad-palm-checks
