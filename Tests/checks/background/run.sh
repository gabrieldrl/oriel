#!/bin/bash
# The background link (kinds 55 to 58, ALPN sill-bg/1; docs/background-plan.md): Sources/StreamProtocol compiled as one module with
# the host's Sources/SillHost/Background/BackgroundPolicy.swift. The kinds, the ALPN,
# the join and its JSON, the registrations, APNs answers, the provider token and the payload.
#   Tests/checks/background/run.sh             compile and run the check
#   Tests/checks/background/run.sh --mutants   one-line mutants of the files it checks; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
