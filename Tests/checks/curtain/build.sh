#!/bin/bash
# usage: build.sh WT OUT [FILE=OVERRIDE ...]
# Compiles the check with StreamProtocol's sources as one module and the host's
# Sources/SillHost/Curtain/CurtainPolicy.swift; FILE=OVERRIDE (a basename, then a path) compiles
# OVERRIDE in FILE's place (the mutants').
WT=$1; OUT=$2; shift 2; T=$(mktemp -d)
cp "$WT"/Sources/StreamProtocol/*.swift "$T"/
cp "$WT/Sources/SillHost/Curtain/CurtainPolicy.swift" "$T/CurtainPolicy.swift"
for o in "$@"; do cp "${o#*=}" "$T/${o%%=*}"; done
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error" ; rm -rf "$T"
