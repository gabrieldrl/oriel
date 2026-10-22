#!/bin/bash
# The Mac's screen off (kind 52; docs/curtain-plan.md): Sources/StreamProtocol compiled as one module with
# the host's Sources/SillHost/Curtain/CurtainPolicy.swift. The kind, CurtainControl's JSON, the window
# list's `curtain`, which events the curtain stops and that Sill's own always pass, and the tap's mask.
#   Tests/checks/curtain/run.sh             compile and run the check
#   Tests/checks/curtain/run.sh --mutants   one-line mutants of the files it checks; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
