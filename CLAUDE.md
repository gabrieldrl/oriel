# Sill

Open-source, free app that streams individual Mac app windows to iPhone and iPad
(designed for iPhone Duo first), with a free Mac companion. Tip jar, no
subscription, no servers. Read `docs/BRIEF.md` before doing product-level work.

**This checkout is gabrieldrl's public fork** (origin gabrieldrl/sill, public on GitHub, so anything
pushed there is visible to everyone; upstream Saffsanity/sill, fetch only: its push URL is `DISABLE`).
Start with `docs/OVERVIEW.md`: what Sill is, the repository map, how it works, the build, and the
fork's own identifiers (bundle IDs `com.gabrieldrl.sill[.mac]`, team JF8R4AVC2H, Bonjour
`_sillgdl._tcp`), which replace the `me.saffer.sill` / `_sill._tcp` values in upstream's docs.
Formerly winstream; the folder still carries the old name.

Where the detail is:
- `docs/NOTES.md`: the upstream maintainer's full working notes (every step's record since the
  spike, the whole Layout and Build and run: every flag, `SILL_TEST_*` hook and `-Sill…` harness
  argument). A code comment that cites "CLAUDE.md, ‹section›" means that section there.
- `docs/*-plan.md`: one per feature: its plan, open questions with the defaults taken, results,
  review, and what is untested on a device.
- `docs/DEVELOPMENT.md`: building, running and testing from source, at length.
- `docs/release-checklist.md`, `docs/app-store-metadata.md`: releasing.

## Current step

**The Mac's sound on the device (2026-10-22, branch `dev`; `docs/mac-sound-plan.md` has the plan,
its open questions with the defaults taken, and the results).** An audio pill beside Touch/Trackpad
opens into a volume slider. While Sill is connected the Mac's sound plays only on the device, never
on the Mac's speakers, unless the pill's Play on Mac (`onMac`, `sound` 2) leaves it there; muted is
the Mac and the device silent; every control is the device's. Built
fresh; upstream's `upstream/wip/audio` was read, not merged.
- Wire (additive, Sound.swift): `WindowList.sound` 1; kind 47 `sound` (a JSON `SoundFormat`, then
  binary packets), kind 48 `soundControl` both ways.
- Mac: `Sources/SillHost/Sound/` (HostSound, MacVolume, SoundEncoder: AAC-ELD 48 kHz, SoundGate:
  pure, `Tests/checks/sound`, SoundPipeline). A synthetic host never taps this Mac: a test tone.
- Device: `iOSClient/Sound/` (SoundPlayer, StreamClient+Sound) and `MacSoundControl`.
- **Untested, for Gabriel** (the plan's list): Sill.app to the iPad with the real tap (the System
  Audio Recording alert, the Mac's speakers silent and back, the slider and the Mac's own keys,
  mute, headphones or AirPlay mid-stream, away through Tailscale).

**The new main stream screen (in progress on `dev`).** `iOSClient/Desktop/`: DesktopScreen (the
picture shaped as a MacBook display, the connect fade-in, Disconnect's ripple, DisplayRipple),
RisingSheet (black rising out of the picture's bottom edge, narrower than it, flaring into the edge
at its base) for AppsTray (the Apps pill and its sheet) and KeyRowSheet (the key row, its caps
lighter under the finger), InfoPanel (the ⓘ above the picture's top-right corner: a glass panel of
latency, frame age, fps, bandwidth, resolution and route), `QuickControls/` (the row;
QuickControlStyle; FlipToggle, MorphingPicker, ColumnPill (the typing pill: keyboard and key row),
MacSoundControl, ClipboardControl (the Mac's copy, on a tap), and QuickPillFocus: one open control
at a time, a touch anywhere else folds it). On this screen the iPad's copies go to the Mac by
themselves, with no switch (StreamClient+Clipboard's `sendClipboardByItself`; iOS asks "Allow
Paste?" unless Settings › Sill › Paste from Other Apps is Allow). `-SillClassicScreen 1` shows the
old StreamScreen.

**A paired Mac, reachable wherever it is (in progress on `dev`; `docs/reachable-plan.md`).** Remote
Access on by default, internet access removed (switch, router query, address name, `--internet`);
the device keeps every VPN address the Mac gives (`SavedMacs.remembering`) and checks saved Macs
not nearby while the home screen shows (`MacProbe`: a pinned TLS handshake stopped at the verify
block), so each card reads "Online · Wi‑Fi", "Online · Tailscale" or "Offline". Gabriel,
2026-10-22: this fork won't be compatible with later Sill releases, so the compatibility floor below
doesn't bind changes like these. Its device tests are in the plan.

**Extended displays (in progress on `dev`; `docs/displays-plan.md`).** A Displays pill beside Apps
opens a sheet of Primary, up to 4 of this device's own displays (CGVirtualDisplay, serials stable per
device so macOS keeps their arrangement) and Add Display; a tap streams one. Disconnect takes the
device's displays now, a lost connection after 30 s; reconnecting brings them back with their
windows. Wire: `StreamSource.display`, `WindowList.displays`/`showing`, kinds 49–51.
Mac: `Sources/SillHost/Displays/` (DisplayPolicy pure, `Tests/checks/displays`). Device:
StreamClient+Displays, DisplaysTray. Untested with a real display; the plan lists the device tests.

**The Mac's screen off (in progress on `dev`; `docs/curtain-plan.md`).** An eye pill between
Clipboard and Disconnect, kept per Mac on the device: the Mac's displays black, the built-in at
brightness 0, its own keyboard and trackpad stopped by an HID event tap (Sill's posted events carry
`CurtainPolicy.marker` and pass). Up while any connection wants it, down when none does. Wire:
`WindowList.curtain`, kind 52. Mac: `Sources/SillHost/Curtain/` (CurtainPolicy pure,
`Tests/checks/curtain`). Device: StreamClient+Curtain. Untested on a device.

**To do, remind Gabriel: layouts per device.** The new screen is laid out for an iPad held sideways
only. Still to design (UX work, Gabriel's call): an iPad upright, a phone upright and sideways, and
the iPhone Duo's poses (the classic StreamScreen and PortraitStreamScreen have each today).

Upstream's open device tests (clipboard, hardware keyboard, Larger Picture, window restore,
reconnect after sleep, the Settings window, away from home, the Duo, and more) are listed in each
feature's plan and in `docs/NOTES.md`'s Current step.

## Working here

- Device builds: the iPad is `00008112-0011712934DA201E`. Build with a derived data path outside
  `~/Documents` (iCloud's file provider tags files inside it and codesign refuses them), then
  install and launch:
  ```
  xcodebuild -project iOSClient/Sill.xcodeproj -scheme Sill -destination 'platform=iOS,id=00008112-0011712934DA201E' -configuration Debug -derivedDataPath <outside ~/Documents> -allowProvisioningUpdates DEVELOPMENT_TEAM=JF8R4AVC2H build
  xcrun devicectl device install app --device 00008112-0011712934DA201E <DerivedData>/Build/Products/Debug-iphoneos/Sill.app
  xcrun devicectl device process launch --device 00008112-0011712934DA201E --terminate-existing com.gabrieldrl.sill
  ```
- The Mac app: `SILL_INSTALL_DIR=~/Applications Scripts/make-app.sh --install --open` (beside the
  official Sill.app in /Applications). Log: `~/Library/Logs/Sill/Sill.log` (both apps write it).
- Before a commit: `Tests/checks/run-all.sh` (every pure check, ~8 min; `--mutants` adds the
  mutants). A change to a checked file updates its check, and a mutant's pattern, in the same
  commit. A new iOS source file needs its four `project.pbxproj` entries by hand.
- The hardware encoder has one engine. While a device streams from Sill.app, don't run `simctl io
  recordVideo`, SillHost streams on the hardware encoder or encoder benchmarks: each shares it
  (the recorder at a higher priority) and costs the stream frames. Test hosts:
  `SILL_TEST_LOOPBACK=1 SILL_TEST_SOFTWARE_ENCODER=1 SILL_TEST_NO_ROUTER=1 SillHost --synthetic`
  (127.0.0.1 alone, never the hardware encoder, nothing posted to this Mac).
- Day-to-day commands are in `docs/OVERVIEW.md` §4; the complete list in `docs/NOTES.md`, "Build
  and run".

## Rules in the code

- Host code is the `SillHostCore` library, reached with `package` access. Never
  `MainActor.assumeIsolated` in core code (under the CLI's dispatchMain the main queue drains on a
  worker thread); hop with `Task { @MainActor }`.
- Sill.app's modal-loop rule (AppDelegate's doc comment): never start NSMenu.popUp, a runModal or a
  terminate that can answer .terminateLater from a Task, a continuation or a main-queue block; only
  from AppKit target/action, SwiftUI Button actions or a run-loop Timer. Errors show inline.
- The CLI's stdout stays byte-identical: core `print`s go through HostLog's shadow.
- Never reconfigure a running SCStream, and never call VideoToolbox from the capture queue (the
  encoder's mailbox and watchdog exist because of a wedged hardware encoder: NOTES.md, "Frozen
  stream").
- Decision logic goes in small pure files (`*Policy`, `*Judge`, `*Layout`) with a folder in
  `Tests/checks`.
- TEST ONLY hooks are honoured only by a host that does not advertise; Sill.app ignores them with
  one line each.

## Compatibility floor

The first public builds (Sill for iPhone and iPad from the App Store, Sill.app from GitHub) set it
for good. Sill.app changes only when its user downloads a new version (its update check only points
at one), and a device can stay on an old version (automatic updates off, an iOS the next version
dropped). So every later host keeps serving devices from the first public build on, and every later
device keeps working with Macs from the first public build on, or each says why
(docs/update-notice-plan.md):
- Kept as they are: the home door as Sill.app 1.0 ships it, TLS with pairing at home
  (docs/home-pairing-plan.md, branch `home-pairing`; it ships before 1.0, Noah 2026-09-25), not
  the plain-TCP `_sill._tcp` door, which only development builds and the CLI without `--pairing`
  keep; the ALPNs `sill/1` and `sill-pair/1`, which every host offers for good at both doors
  (`RemoteTLS.serverALPNs`: a later generation's `sill/2` only ever goes beside them); the 14-byte
  header; kinds 0–28 and 32 and their payloads (HEVC with ParameterSets; the JSON of Switcher,
  Input, Viewport, HostSettings, Remote, Compatibility, Pointer, MacMenu, Gesture and Clipboard;
  this fork's kinds 47 and 48, the Mac's sound (Sound.swift), go only to and from a host whose window
  list says `sound` 1;
  29 to 31 stay free, 29 the audio plan's, 30 and 31 pull request #66's), inside `sill/1` at
  both doors (19 and 20 on their own `sill-pair/1` connection, the next bullet); the ping echo; a
  kind 16 within 2 s of the first window list, one per connection since Sill for Mac 0.5.1 (away
  from home, docs/remote-bundle-plan.md §4): its `settings` the pair that connection's controls
  set (the away quality for a device away), and its optional `away` (AwayQuality, from a host with
  an identity: Sill.app, SillHost --remote or --pairing) and `link` (LinkReport, only while a link
  does not keep up; its `state` a string,
  which a device reads as keeping up when it does not know it); kind 22's `reason`, `message` and
  `reconnect`; the
  Mac's menus as MacMenu.swift has them (docs/menu-bar-plan.md §3):
  a kind 27 without an id is the device's subscription, and only a subscriber is served (another
  connection's fetches and choices are answered "The menus changed…", nothing read or pressed); an
  id is a path of child indexes that names one item for every device within one version, and a
  request of another version is answered with that note and never acted on; a fetch and a choice
  carry the title the device showed, and the host reads or presses only while the item there still
  has it; a device's tokens come back in `answering`; the fields as they are (MacMenu's `version`,
  `app`, `bundleID`, `menus`, `answering`, `menu`, `items`, `more`, `pressed`, `stale`, `note`;
  MacMenuItem's `id`, `title`, `separator`, `enabled`, `mark`, `key`, `submenu`; FetchMenu's and
  PressMenuItem's `version`, `id`, `title`, `token`); a trackpad gesture (kind 28, Gesture.swift)
  goes only to a host whose window list says `gestures` 1 or more, as one of its six names with
  `fingers`, and a later generation of gestures says 2 and goes only to a host that says so; the
  clipboard (kind 32, Clipboard.swift, docs/clipboard-plan.md) goes from a device only to a host
  whose window list says `clipboard` 1 or more (an Int: 1 is text, a later generation with images
  says 2), and from a host only to a connection that sent a kind 32 and no `stop` since: any kind
  32 subscribes, `{"stop":true}` ends it, `text` (at most 256 KB, the JSON at most 1 MiB) becomes
  the receiver's clipboard, `image` is reserved for that later generation; a subscription says what
  the device takes, `{}` being text alone, so a host sends `image` only to a connection whose
  subscription carries a later field saying it takes images (`"accepts":2`, say), never to one that
  sent `{}`.
- Pairing as 1.0 does it (docs/home-pairing-plan.md §3): the Bonjour TXT keys `r` (the recognition
  tag) and `p` ("1" pairing required, "0" open, no `p` a plain door, any other value read as "1");
  a `sill-pair/1` connection is exactly one kind 19, with no hello (the device gate judges sessions
  only), and one kind 20, then the Mac closes it; kind 19's methods `qr`, `code` and, at the home
  door, `ask` and `cancel` (the remote door answers both `closed`), at `v` 1: a host answers any other `v`
  `closed` without counting a try, so a later method or proof format comes with a later `v`, never
  as a new method at 1, which a 1.0 host counts as a wrong code; kind 20's reasons `code`,
  `closed`, `expired`, `stopped`, `busy` and, after an ask, `shown`, `openOnMac` and `locked`, with
  their meanings (`PairResult.knownReasons`: a later reason comes with its `message`, which 1.0
  devices show as it is); an ok without a proof only as `method` "cable", to an ask that claimed
  the cable; and pairing is never refused for the device's age.
- Additive only (HostSettings.swift's rules): new fields optional, never renamed or retyped; kind
  numbers never reused; no new case in an enum an older peer decodes. `StreamSource` keeps its
  three cases (a new source goes in an optional field, with `active` still one of the three). A new
  `InputEvent` case, scroll phase or window command goes only to a host that said it takes it (a
  kind or a field only newer hosts send), and a gesture ends with a scroll phase the first build
  knows.
- A device is refused, never served wrong. A host that can no longer serve older devices raises
  `DeviceGate.minimumDeviceVersion` ("0" today) by the plan's §4.6, and they get kind 22 "update"
  before anything else. A device from 2026-09-25 on that receives it shows the host's message word
  for word, with its App Store link, and does not reconnect; older development builds cannot. At
  the TLS home door only devices from home pairing on receive it (Decided, below). Kind 22 reaches
  a 1.0 device only inside a `sill/1` session, so such a host still completes that device's
  `sill/1` handshake and reads its hello through the gate before refusing it: a host that stopped
  offering `sill/1` would leave it a failed handshake (-9838), "disconnected" and a redial every
  few seconds, for ever.
- Every device says hello first (kind 23: its version, build, protocol and name), and every host's
  window list gives its version and protocol (`hostVersion`, nil from SillHost and from Macs
  before 2026-09-25). A later device facing an older Mac tells what it lacks from these and from
  which kinds and fields arrive, and says "Update Sill on ‹Mac›", as the Settings panel already
  does for a Mac without kind 16.
- `SillProtocol.current` (1) rises only with a change an older peer cannot skip, and the floor
  rises with it.
- Decided (Noah, 2026-09-25; the plan's open question 14): home pairing ships before 1.0, so the
  floor is the TLS home door with pairing, and no 1.0 device speaks plain TCP to Sill.app.
  Settled at the merge of main into `home-pairing` (2026-09-27, d11aa60; home pairing landed
  second): the hello goes first inside TLS at both doors, and the device gate runs in `Door`, once
  the key is admitted, one place for both TLS doors (`StreamServer.gate`; the CLI's plain door
  without `--pairing` runs it at `.ready`); what changed while it held a session (the key removed,
  Require pairing on, Remote Access or internet access off, the session limit, Direct Wireless
  off) is judged again by `DoorPolicy.afterGate`, with the goodbye and the line that change's own
  close gives. 1.0's TLS home door is `SillProtocol` 1 with ALPN `sill/1`, as the remote door is:
  pairing on the home door is part of protocol 1, no longer an example of what raises it
  (Compatibility.swift, docs/update-notice-plan.md §3.2 and §4.6), and a later generation raises
  both: `sill/2` is offered beside `sill/1` and `sill-pair/1`, never instead of them (the first
  bullet). Builds from before home
  pairing dial plain TCP and say hello in plaintext: at the TLS door they get a failed handshake
  and EOF, never kind 22 "update", and redial. Only development and TestFlight builds are that
  old, so no plaintext path or sniffer answers them.

## Conventions

- Swift, Apple frameworks only. No third-party dependencies unless a decision
  in `docs/BRIEF.md` says so. Zero operating costs is a hard rule.
- Threading is by hand: capture queue → VT callback thread → network queue.
  Keep it explicit and commented.
- HEVC, no B-frames, real-time mode. AV1 is out (no hardware encode on Apple
  silicon as far as we know).
- Latency beats quality. Drop frames before queuing them.
- Don't add features the current milestone doesn't need.
- Write the record of a step in its plan (`docs/<feature>-plan.md`); keep its
  Current step entry here to a few lines, and drop it once the step is done.

## Decisions already made (don't relitigate without asking Noah)

- Free app, tip jar, open source. Not paid, not subscription.
- iCloud auto-pairing (same Apple Account, Mac just appears) for milestone 5.
- Native feel is the bar: Flighty-level polish, iOS conventions, Duo layouts.
- License: Apache-2.0.
- v1 out of scope: hole punching, multi-window, layout customization (audio
  was too; this fork and upstream both now have it).
