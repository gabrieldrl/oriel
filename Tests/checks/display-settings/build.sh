#!/bin/bash
# usage: build.sh WT OUT [DisplaySettingsMemory.swift override]
# Compiles the device's iOSClient/DisplaySettingsMemory.swift with StreamProtocol's sources as one module
# (its `import StreamProtocol` sits behind canImport, so nothing is stripped).
WT=$1; OUT=$2; T=$(mktemp -d)
cp "$WT"/Sources/StreamProtocol/*.swift "$T"/
cp "${3:-$WT/iOSClient/DisplaySettingsMemory.swift}" "$T/DisplaySettingsMemory.swift"
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error" ; rm -rf "$T"
