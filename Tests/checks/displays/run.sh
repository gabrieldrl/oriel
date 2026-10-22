#!/bin/bash
# The extended displays (kinds 49 to 51; docs/displays-plan.md): Sources/StreamProtocol compiled as one
# module with the host's Sources/SillHost/Displays/DisplayPolicy.swift (build.sh strips its `import
# StreamProtocol`). The kinds, StreamSource.display and how a window list says it, DisplayControl's
# and DisplayList's JSON, the serial numbers, slots, sizes, how a device's displays end, which windows
# go back and where, and the memory's JSON.
#   Tests/checks/displays/run.sh             compile and run the check
#   Tests/checks/displays/run.sh --mutants   one-line mutants of the files it checks; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
