# The background link, and agents that notify

Gabriel, 2026-10-22. Two levels of connection, a link to each connected Mac that outlives the
stream, and the first feature built on it: a notification when a coding agent on a connected Mac
finishes a turn.

## What Gabriel asked for

- **Close and Disconnect.**
  - Tapping ✕ closes the stream, back to the home screen. The Mac stays *connected*.
  - Holding ✕ for 2 s disconnects fully. A red fill sweeps across the pill while it is held.
- **Home screen.** A connected Mac's card shows **View** and **Disconnect** instead of Connect. Several
  Macs can be connected at once, with one viewed at a time.
- **While a Mac is closed but still connected:**
  - The stream, the displays, the sound and the screen-off all stop, as they do when a session ends.
  - Only the background link runs.
- **Settings** (a button on the home screen) opens a modal. Its one tab today is **Agents**:
  - "Get notified when an agent on any connected Mac finishes", off by default.
  - When it is on, a list of Macs to pick from.
- **The background service** is its own layer, with agents as its first feature, so later
  background features build on it.
- **Disconnecting stops everything** on the Mac for this device: no watching, no pushes.

## Decided (Gabriel, 2026-10-22)

1. **Notifications go through APNs, sent by the Mac itself.** There is no server: the Mac posts
   straight to Apple.
   - The Mac holds an APNs auth key (.p8) from Gabriel's developer account. The key lives outside
     the repository (see "The push key").
   - This works for this fork. A public build would need another way to send pushes.
2. **"Finished" means a turn ended.**
   - Claude Code: an `assistant` record with `stop_reason` `end_turn`, not on a side chain.
   - Codex: an `event_msg` whose payload is `task_complete`, from a thread that is not a sub-agent's.
   - An interrupted turn is not a finish (Claude writes no `end_turn`; Codex writes `turn_aborted`).
3. **A connection that drops is not a disconnect.**
   - The device keeps redialling while Sill is in the foreground.
   - The Mac keeps the device's registration whether or not a link is up.
   - Only a Disconnect from the device ends it, and then the Mac stops monitoring for that device
     at once.
4. **Several Macs can be connected at once.** There is one link per Mac, app-wide (`MacLinks`).
5. **Closed but connected:** the stream session ends; only the link stays.

Defaults taken without asking:

- **A Mac out of reach at Disconnect.** The device keeps the leave and sends it at the next reach. The
  Mac also forgets a device it has not heard from in 30 days, and any device whose push token APNs
  says is gone (410, or 400 BadDeviceToken).
- **The Mac list in Settings.** It shows every saved Mac. Turning the switch on ticks each one; you
  untick the ones you don't want. A Mac notifies only while it is connected.
- **Codex's sub-agents** (`source` starting `{"subagent"`) neither notify nor show in session
  lists.

## Why APNs and not a held connection

iOS suspends an app within seconds of leaving the screen, and its sockets with it.

- The link is live only while Sill is in the foreground (or just left it).
- The registration is what persists. The Mac keeps it on disk, so it survives the link, the
  device's suspension and a restart of Sill.app.
- Notifications reach the device through APNs whether Sill runs or not.

## The wire

A third ALPN, `sill-bg/1`, beside `sill/1` and `sill-pair/1` (`RemoteTLS.backgroundALPN`).

- Both TLS doors take it with the same trust as a session: a paired key. At home, any key while
  Require pairing is off.
- It never reaches StreamServer's clients. It is not a stream session, gets no catalog and no
  frames, and doesn't count toward the session limit. It has a limit of its own: 16 links.
- Same 14-byte header and JSON payloads.
- First the hello (kind 23), then the device's `LinkJoin`. These kinds go on the link only:

| Kind | Name | Direction | Payload |
| --- | --- | --- | --- |
| 55 | `linkJoin` | device → Mac | `LinkJoin {token, push?: PushTarget, features: LinkFeatures}`. Registers, or replaces, this device's registration. Sent at each link's start and at every change. |
| 56 | `linkState` | Mac → device | `LinkState {answering, registered, pushProblem?}`: the join's answer. `pushProblem`: `noKey`, `rejected`. |
| 57 | `linkLeave` | device → Mac | `{}`. Forget this device. Its monitoring stops and the Mac closes the link. |
| 58 | `agentEvent` | Mac → device | `AgentEvent {provider, session, title, project, kind, at}`, live while the link is up. |

- 53 and 54, the agents' report and query, move onto the link.
- 10 and 11, ping and pong, keep the link alive: the device pings every 15 s and the Mac echoes.
- The stream path drops its agents. `WindowList.agents` and the stream's 53/54 handling go; they
  were never committed.
- `PushTarget {token (hex), environment ("development" | "production"), topic (the bundle id)}`.
- `LinkFeatures {agentsNotify: Bool}`. Later features add optional fields here.

## The Mac

`Sources/SillHost/Background/`:

- **`BackgroundPolicy`** (pure, `Tests/checks/background`):
  - applying a join or a leave;
  - expiry;
  - who wants what;
  - an APNs answer's verdict;
  - the push payload;
  - the JWT's header and claims.
- **`BackgroundRegistry`:** the registrations, keyed by the device's key fingerprint.
  - Sill.app keeps them in `~/Library/Application Support/Sill/background.json`.
  - A test host keeps them in memory only.
- **`BackgroundServer`:** the links (framing, hello, join, leave, ping), and the features it serves.
  A feature is an object it calls with the registrations as they change and with every message it
  doesn't handle itself (`BackgroundFeature`).
- **`PushSender`:** APNs over HTTP/2 (URLSession). The JWT is ES256 (CryptoKit), refreshed every 50
  minutes. The sandbox or production host is picked by the target's environment.

`Sources/SillHost/Agents/`:

- **`AgentWatch`:** FSEvents on `~/.claude/projects` and `~/.codex/sessions`.
  - It runs only while some registration wants agent notifications.
  - It reads each changed file from its last offset. Files are first seen at their end, so old turns
    never notify.
  - New lines go to `AgentPolicy.turnEnds`. It waits 10 s per session before notifying again, and
    one message id counts once.
  - Titles come from the same readers as the lists.
- **`AgentsFeature`:**
  - watches while wanted;
  - pushes each finish to every device that wants it, and sends `agentEvent` on live links;
  - answers 54 with 53 on a link.

## The device

`iOSClient/Background/`:

- **`MacLinks`** (one for the app):
  - The connected Macs and the leaves still to send, kept in UserDefaults.
  - A `BackgroundLink` per connected Mac.
  - The push token, and the agent settings.
- **`BackgroundLink`:**
  - Dials the Mac's saved addresses at its remote door (RemoteConnector, `sill-bg/1`, pinned).
  - Sends the hello, then the join.
  - Reads with MessageReader and pings every 15 s.
  - Redials after a drop (2, 4, 8 … 30 s) while the app is active. It stops when the app goes to
    the background and comes back on `active`.
- **`AgentAlerts`:** the notifications' delegate: a notification shows as a banner even while Sill
  is open. `MacLinks` asks the permission when the switch first turns on and registers for remote
  notifications; SillAppDelegate hands it the token, which goes in every link's join.
- **`Desktop/SettingsScreen`:** the modal, with its Agents tab: the switch, then each saved Mac's
  own switch and its line ("Connected", "Not connected", "The Mac has no push key yet").

Other changes on the device:

- **StreamClient:** a session that reaches a saved Mac joins it to `MacLinks` (in `markConnected`,
  `remoteSessionReady`, and when a verified kind 18 names the Mac later). Close ends the session as
  Disconnect did. Forget disconnects first.
- **CloseControl** (QuickControls): a tap closes; a 2 s hold, red sweeping across the circle from its
  leading edge, disconnects. A release after 0.5 s and before 2 s does nothing. VoiceOver: Close,
  and a Disconnect action.
- **HomeScreen:** a connected Mac's card has View in Connect's place, and Disconnect beside it (its
  menu too). A gear beside Add a Mac opens Settings.
- **Entitlements:** none for now (a free team has no push; "Push needs a paid Developer Program
  team" below). With a paid team, `aps-environment` development; an App Store export turns it into
  production, and `MacLinks` sends the token's environment from the build (DEBUG: development).

## The push key

Make it once, in Certificates, Identifiers & Profiles: Keys, then +, then Apple Push Notifications
service (APNs). Download `AuthKey_<KEYID>.p8` and put it in `~/Library/Application Support/Sill/Push/`
on each Mac.

- The key ID comes from the file's name. The team is JF8R4AVC2H unless
  `Push/push.json` gives `{"teamID": …}`.
- Without a key the Mac still registers the device, and Settings shows "‹Mac› has no push key".
- The iOS app gets the `aps-environment` entitlement: development for Debug builds, production
  for Release.

## Results (2026-10-22)

- Host, on a synthetic host with a fake home (`SILL_TEST_AGENTS_HOME`), through
  `Scripts/sillclient.py --link`:
  - A join is answered `registered`, `pushProblem` noKey.
  - The agents report comes over the link.
  - The watch starts with `agentsNotify` and stops with a join that turns it off or a leave.
  - A turn that ended before the watch began notifies nothing; nor does a `tool_use` stop.
  - The same `end_turn` twice counts once.
  - Claude Code and Codex finishes both arrive as kind 58.
  - A link dropped without a leave keeps the registration and the watch.
  - Pings are answered every 15 s.
- Checks: `background` (50), `agents`, `door-policy`, `protocol`; mutants for `background` and
  `agents`.
- iPad simulator against that host (paired with `-SillPairURL`; DEBUG `-SillAgentsNotify 1|0` and
  `-SillDisconnectAll 1` stand in for the switch and Disconnect):
  - Connecting joins the Mac ("is connected (agent notifications off)"), and the link comes up.
  - Relaunched with no stream, the link comes up by itself, and the card shows View and Disconnect.
  - The switch on: the Mac starts watching; LinkState says `noKey`; a turn ended in the fake home
    reaches the device as kind 58.
  - Disconnect from a launch, with no link up: its own link says the leave. The Mac: "disconnected;
    nothing runs for it now." and "Agents: no longer watching."; the card is back to Connect.
  - Fixed on the way: Disconnect and View wrapped at an upright iPad's width.
  - An unanswered notification prompt keeps the app inactive, so no link starts until it's
    answered (expected; the simulator needed a reboot to clear it).
- Device: builds for the iPad with no entitlement (below); installed, its link registers with
  Sill.app ("is connected (agent notifications on, no push token yet)") and the watch starts. Not run on it yet; the
  hold on ✕ and the Settings screen untested by touch.

## Push needs a paid Developer Program team (2026-10-23)

Team JF8R4AVC2H is a free personal team. Apple offers the Push Notifications capability and APNs
keys only to Developer Program members, so this device can't register for pushes and no Mac has a
key to send them with. `iOSClient/Sill.entitlements` (`aps-environment`) was taken out again: with
it, a device build on a free team fails ("Provisioning profile … doesn't include the Push
Notifications capability"). `registerForRemoteNotifications` fails with one DEBUG line, and every
join goes without a token.

What still works: the link, the registrations, the watch, and kind 58 to a device whose link is
up. The Mac's APNs sender is kept for a paid team: put `CODE_SIGN_ENTITLEMENTS = Sill.entitlements`
(with `aps-environment` development) back in both configurations, and the key as in "The push key".
Gabriel to choose a way to notify without APNs (local notifications while the link is up, an
iMessage from the Mac, or the Developer Program).

## Untested on a device (for Gabriel)

- Close, then the home card: View and Disconnect. View connects again; Disconnect ends it (the
  Mac's log: "Background: ‹iPad› disconnected; nothing runs for it now.").
- Hold ✕ for 2 s: the red sweep, then the Mac is disconnected. Let go halfway: nothing.
- Settings › Agents: the switch asks for notifications once; each Mac's line.
- With the key and the capability: a finished Claude Code or Codex turn notifies with Sill closed,
  and as a banner with it open. One per turn, none for a sub-agent's.
- Disconnect with the Mac out of reach: the leave goes when Sill next opens with the Mac in reach.
- Forget a connected Mac: it is disconnected.
- Two Macs connected at once, each notifying.
- Away from home through Tailscale (the remote door), and with Remote Access off (the link is
  refused: `remoteOff`).
