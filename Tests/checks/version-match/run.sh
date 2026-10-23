#!/bin/bash
# Whether a Mac and a device run the same Oriel (Sources/StreamProtocol/VersionMatch.swift, compiled with
# the rest of Sources/StreamProtocol): the verdict, which side to update, and the words each side shows.
#   Tests/checks/version-match/run.sh             compile and run the check
#   Tests/checks/version-match/run.sh --mutants   one-line mutants of VersionMatch.swift; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
swiftc -O Sources/StreamProtocol/*.swift "$here/main.swift" -o "$out/check"
"$out/check"
