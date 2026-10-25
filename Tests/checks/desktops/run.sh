#!/bin/bash
# The Mac's desktops (kinds 53 to 55; docs/desktops-plan.md): Sources/StreamProtocol compiled as one
# module with the host's Sources/SillHost/Desktops/DesktopPolicy.swift (build.sh strips its `import
# StreamProtocol`). The kinds, how a window list says it, DesktopControl's and DesktopList's JSON, a
# desktop's picture, and the policy: reading the window server's list, the names, which set is which
# display, the steps of a switch, and whose a picture is.
#   Tests/checks/desktops/run.sh             compile and run the check
#   Tests/checks/desktops/run.sh --mutants   one-line mutants of the files it checks; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
