# Agents

Gabriel, 2026-10-22: Sill shows the coding agents on the connected Mac, Claude Code and Codex: whether
each is installed, its remaining usage and its sessions. An Agents pill beside Displays opens a full
screen of two columns, one per agent, with the usage at the top and the sessions under it. This step
is the back end and its primitives. The screen is plain, to be designed on top. Watching a session's
transcript live comes later.

**Since, the same day:** the pill, the screen and the stream path are gone; the agent UX is to be
built afresh, targeted. Kinds 53 and 54 now go on the background link only
(docs/background-plan.md), with `MacLinks.askAgents` and `MacLinks.agentReports` as the device's
primitives, and the Mac watches for finished turns (AgentWatch) while a device wants them.

## Decisions (Gabriel)

- Both agents, found by their command-line tools: `claude` (`~/.local/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin`, `PATH`) and `codex`. Their data folders are `~/.claude` and `~/.codex`.
- Usage:
  - Claude's comes from Anthropic's usage endpoint (`/api/oauth/usage`), with Claude Code's own
    sign-in from the Keychain (`Claude Code-credentials`). macOS asks once. Sill never refreshes
    the sign-in: a refresh would replace Claude Code's own and sign it out.
  - Codex's comes from disk: the newest `rate_limits` in its session files.
- Sessions: the last 30 days by default, with a filter (7, 30 or 90 days, or all).
- Nothing to switch on: a connected device may ask, as for the Mac's windows.
- Changes are looked for only when asked: no file watching yet. That comes with watching a
  session.

## What is read

- Claude Code: `~/.claude/projects/<folder>/<session>.jsonl`, one transcript per session.
  - The first 64 KB give the folder, branch, start and first prompt.
  - The last 128 KB give the newest `custom-title` (the session's name), `last-prompt`, the
    model and the last activity.
  - `~/.claude/sessions/<pid>.json` names the sessions running now (their process alive).
- Codex: `~/.codex/state_5.sqlite`'s `threads`, read only: title, folder, branch, model, tokens,
  created, updated, archived (left out).
  - Its rate limits are in the newest `rollout-*.jsonl` files' `token_count` events (used %,
    window, reset, plan, credits).
- Only what a list shows ever leaves the Mac: titles, folders, times, models, token counts.
  Never a transcript's contents.

## Caching

- Mac: each Claude transcript's summary is kept by path, size and modified time, so a request
  reads only files that changed. Claude's usage is kept for 60 s, so many requests make one call.
- Device: the last report per Mac (`Caches/Agents/<macID>.json`), shown at once with its age. A
  new request goes when the screen opens and the report is older than 15 s, and on a pull or a
  filter change. Reset times count down on the device.

## The wire (additive)

- ~~`WindowList.agents: Int?`~~: removed. A host answers on the background link (`sill-bg/1`),
  which a host without it refuses at the TLS handshake.
- Kind 53 `agents`, host → device: `AgentReport {answering, at, providers: [AgentProvider]}`.
  - `AgentProvider {id, name, installed, version?, usage?, usageProblem?, sessions, more?}`.
  - `AgentUsage {limits: [AgentLimit {id, name, usedPercent, resetsAt?, windowMinutes?}], plan?,
    asOf, credits?}`.
  - `AgentSession {id, provider, title, project?, branch?, model?, updatedAt, createdAt?,
    running?, tokens?}`.
- Kind 54 `agentQuery`, device → host: `{token, days?, limit?, providers?, usage?}`. It is
  answered with one kind 53, carrying the token.

## Where it is

- Wire: `Sources/StreamProtocol/Agents.swift`.
- Mac: `Sources/SillHost/Agents/`.
  - AgentPolicy: pure, `Tests/checks/agents`. It parses the records, the limits and the usage
    endpoint's answer, and picks the sessions.
  - AgentReaders: the files, the database, the Keychain and the endpoint.
  - AgentsFeature: a BackgroundFeature: queries on its own queue, and the watch.
  - AgentWatch: FSEvents on the transcripts; a turn's end (AgentPolicy's `claudeTurnEnds`,
    `codexTurnEnds`) becomes a kind 58 and a push.
- Device: `iOSClient/Background/MacLinks.swift` (`askAgents`, `agentReports`, `lastFinish`). No
  screen yet.

## Results (2026-10-22)

- `Tests/checks/agents`: 75 checks. Its mutants found two gaps, now closed: a meta record with
  plain words, and the 500-session cap. A third mutant didn't compile and was rewritten.
- On the synthetic host (loopback, software encoder), with an iPad simulator and `-SillAgentsOpen 1`:
  - The host read 30 days of this Mac's Claude Code and Codex sessions, with versions, running dots
    and models.
  - Codex showed its Weekly limit, its reset, its credits and "As of 4 days ago".
  - Claude's usage showed "isn't available right now", as a synthetic host never reads the Keychain.
  - A screen opened before the window list now asks once the list says `agents` 1.
  - A long branch is shortened in the middle, and the time always shows in full.

## Untested on a device (for Gabriel)

- The Keychain prompt in Sill.app. Claude's usage, and its answer when the sign-in has expired.
- Both columns on the iPad. The filter. The cache shown at once on a second open.
