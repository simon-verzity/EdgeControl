#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/checks
swiftc Sources/EdgeControl/MediaPlaybackController.swift Tests/MediaPlaybackChecks.swift -o build/checks/media-playback-checks
build/checks/media-playback-checks "$@"
