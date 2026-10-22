#!/bin/bash
# Each display's settings on the device (iOSClient/DisplaySettingsMemory.swift; docs/displays-plan.md,
# "Settings per display"), compiled with Sources/StreamProtocol as one module: which memory a source
# uses, what a display shown again sends and what one shown first keeps, and what a pick changes.
#   Tests/checks/display-settings/run.sh             compile and run the check
#   Tests/checks/display-settings/run.sh --mutants   one-line mutants of the file it checks; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
