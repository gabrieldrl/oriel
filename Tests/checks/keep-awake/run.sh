#!/bin/bash
# Extended Use (kind 56; docs/extended-use-plan.md): Sources/StreamProtocol compiled as one module with
# the host's Sources/SillHost/KeepAwake/KeepAwakePolicy.swift (build.sh strips its `import
# StreamProtocol`). The kind, KeepAwake's JSON, the window list's `keepAwake`, the modes, when the Mac
# is held, when the helper is registered, what the state says stops it, and the modes offered.
#   Tests/checks/keep-awake/run.sh             compile and run the check
#   Tests/checks/keep-awake/run.sh --mutants   one-line mutants of the files it checks; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
