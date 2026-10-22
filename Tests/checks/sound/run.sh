#!/bin/bash
# The Mac's sound (kinds 47 and 48; docs/mac-sound-plan.md): Sources/StreamProtocol compiled as one
# module with the host's Sources/SillHost/Sound/SoundGate.swift (build.sh strips its `import
# StreamProtocol`). The kinds, SoundControl's JSON, SoundPackets' binary form both ways and every
# malformed payload it refuses, SoundFormat's, the silence gate (its threshold, its hangover, a
# segment's start and end) and the batching of packets into messages; then a random model of a
# stream of peaks against what the device must receive.
#   Tests/checks/sound/run.sh             compile and run the check
#   Tests/checks/sound/run.sh --mutants   one-line mutants of the files it checks; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
