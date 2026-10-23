#!/bin/bash
# The Mac's coding agents (kinds 53 and 54; docs/agents-plan.md): Sources/StreamProtocol compiled as one module with
# the host's Sources/SillHost/Agents/AgentPolicy.swift. The kinds, the report's JSON, the window
# list's `agents`, Claude Code's transcripts, Codex's limits, the usage endpoint's answer, the sign-in and the pick.
#   Tests/checks/agents/run.sh             compile and run the check
#   Tests/checks/agents/run.sh --mutants   one-line mutants of the files it checks; each must fail it
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
if [ "${1:-}" = "--mutants" ]; then run_mutants python3 "$here/mutants.py" "$root"; exit; fi
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
