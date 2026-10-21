# Sill: project overview

A short guide to this repository for someone who just forked it. It condenses
`CLAUDE.md` (the upstream maintainer's ~6,000-line working notes), `docs/BRIEF.md`,
`docs/DEVELOPMENT.md` and the plan files, and adds a snapshot of upstream activity
as of 2026-10-21. When this file and the code disagree, the code wins; when you
need the full detail, `CLAUDE.md` and `docs/DEVELOPMENT.md` have it.

## 1. What Sill is

Sill streams individual Mac app windows (or the whole desktop) to an iPhone or
iPad, where you use them with touch, Apple Pencil, an on-screen trackpad or a
hardware keyboard. It was designed for the iPhone Duo first (iOS 27.1), iPad
second. It is free and open source (Apache-2.0) with a tip jar. There are no
accounts and no servers: the device talks to the Mac directly, at home, over USB,
over peer-to-peer Wi-Fi, or through your own VPN.

Two apps ship: **Sill for Mac** (`Sill.app`, a menu bar host, notarized Developer ID
download and Homebrew cask, not the Mac App Store) and **Sill for iPhone and iPad**
(App Store). The latest release is **0.5.1** (2026-10-09); `main` has several
features merged since then that are not yet released.

**Pipeline:** `ScreenCaptureKit (per window) → VideoToolbox HEVC (real time, no B-frames) → Network.framework TLS 1.3 over TCP + Bonjour → AVSampleBufferDisplayLayer on the device`, with input going back the same connection and posted on the Mac as CGEvents.

## 2. Repository map

| Path | What it is |
|---|---|
| `Package.swift` | SwiftPM. Products `StreamProtocol`, `SillHost` (CLI) and `SillMenuBar` (Sill.app's executable). `SillHostCore` (folder `Sources/SillHost`) is a library with no product, so the iOS project never sees it. |
| `Sources/StreamProtocol/` | The wire format, shared by Mac and iOS. Change it in one place. |
| `Sources/SillHost/` | The host library: capture, encode, network, input, virtual display, pairing, remote access. |
| `Sources/SillHostCLI/` | `SillHost`, the same host on the command line (dev and testing). |
| `Sources/SillMenuBar/` | `Sill.app`: AppKit menu bar app, Settings window, update check. |
| `Sources/CaptureProbe/`, `Sources/VirtualDisplayProbe/` | Diagnostic experiments, not shipped. |
| `iOSClient/` | The iPhone/iPad app, `Sill.xcodeproj` (a hand-maintained Xcode project). |
| `Tests/checks/` | ~50 "pure checks": standalone Swift programs that compile the decision-making files and test them (plus mutation tests). |
| `Tests/touchrig`, `Tests/duorig`, `Tests/keyrig` | Simulator-only rigs (private interfaces): touch surfaces, Duo fold poses, hardware keyboard. |
| `Scripts/` | `make-app.sh`, `make-dmg.sh`, `release.sh`, `release-ios.sh`, and test tools: `sillclient.py` (a fake device), `sillrelay.py` (a lossy/slow link), `sillfeed.py` (a fake update feed), `pacing/`, `encoder-check/`, `menu-check/`, `restore-probe/`. |
| `Packaging/` | Sill.app's `Info.plist`, entitlements, iOS export options. |
| `design/` | The app icon SVG, disk image background, App Store screenshots. |
| `site/` | getsill.app: plain HTML on GitHub Pages, no build step. |
| `docs/` | `BRIEF.md` (product decisions), `DEVELOPMENT.md` (build/run/test, user-facing behaviour), one `*-plan.md` per feature, the release checklist and App Store metadata. |
| `.github/workflows/` | `ci.yml` (build + pure checks on every PR), `release.yml`, `testflight.yml`. |

### Key host files (`Sources/SillHost/`)

- `StreamCoordinator.swift`: the main actor that owns the pipeline: switches sources, applies viewports, restarts on setting changes, falls back to the software encoder, sends menus, says goodbye at quit.
- `WindowCapture.swift` / `SyntheticCapture.swift`: ScreenCaptureKit capture, and the `--synthetic` test pattern.
- `HEVCEncoder.swift`, `EncoderMailbox.swift`, `EncoderSlowState.swift`, `EncoderProbe.swift`: the encoder, its one-slot mailbox and hang watchdog, and recovery from the hardware encoder's "slow state".
- `StreamServer.swift`, `Door.swift`, `DoorPolicy.swift`, `RemoteServer.swift`, `RemoteAccess.swift`: listeners, TLS doors, who may connect where, pacing for remote links.
- `HostIdentity.swift`, `KeychainIdentityStore.swift`, `PairingWindow.swift`, `CableLink.swift`: the Mac's key, paired devices, pairing codes, USB-cable auto-pairing.
- `InputInjector.swift`, `KeyStrokes.swift`, `GestureChords.swift`, `PointerControl.swift`: turning device input into CGEvents.
- `VirtualDisplay.swift`, `VirtualStage.swift`, `WindowSizer.swift`, `WindowRestore.swift`: the private-API virtual display, and the Accessibility-resize fallback that puts windows back afterwards.
- `MenuReader.swift`, `MenuMirror.swift`: reading the streamed app's menu bar over Accessibility.
- `HostClipboard.swift`, `HostConfig.swift`, `LinkJudge.swift`, `AwayPolicy.swift`, `HostLog.swift`.

### Key iOS files (`iOSClient/`)

- `StreamClient.swift` (+ `+Home`, `+Remote`, `+Viewport`, `+Clipboard`): discovery, connecting, the session.
- `SessionLink.swift`, `MessageReader.swift`: the connection and message parsing.
- `HEVCDisplayView.swift`: decode and display (AVSampleBufferDisplayLayer), the pointer sprite.
- `ContentView.swift` (connect screen), `StreamScreen.swift`, `PortraitStreamScreen.swift`, `PhonePortraitLayout.swift`.
- `InputOverlay.swift`, `TrackpadView.swift`, `TrackpadGestures.swift`, `HardwareKeyboardPolicy.swift`, `KeyChords.swift`: input.
- `DuoPosture.swift`, `DuoPostureReader.swift`: iPhone Duo hinge and fold (iOS 27.1 SDK).
- `HostSettingsPanel.swift`, `SavedMacs.swift`, `AddMacCard.swift`, `CodeScanner.swift`, `PairingOverlay.swift`, `MacMenu*.swift`, `TourPolicy.swift`/`TourOverlay.swift`.

A pattern worth knowing: rules are kept in small **pure** files (`*Policy.swift`,
`*Judge`, `*Layout`) so `Tests/checks` can compile and test them without a device.

## 3. How it works

**Capture.** ScreenCaptureKit captures one window
(`SCContentFilter(desktopIndependentWindow:)`) or a display (the "Desktop"
source) in 420f. Capture runs only while a device is connected. The frame rate
follows the device (120 on ProMotion, 60 on iPad mini or in Low Power Mode),
capped by `maxFPS`.

**Encoder.** VideoToolbox HEVC in real-time mode with no B-frames, one frame in
flight, a one-slot mailbox (newer frames replace older ones rather than queue),
and a watchdog. If the hardware encoder hangs, the host switches to the software
encoder and keeps re-checking the hardware until it can return. Quality presets
are bitrates per 60 fps: Low 4, Efficient 8, Balanced 15 (default), High 25,
Pro 40, Ultra 80, Extreme 150 Mbps.

**Network, doors and pairing.** The host has two "doors":
- The **home door**: advertised over Bonjour as `_sill._tcp` (`_sillgdl._tcp` in this fork), TLS 1.3 with each
  end pinned to the other's key. Pairing at home is by "ask" (tap an unpaired
  Mac and it opens a pairing window), a QR code, a 12-digit code, or
  automatically over the USB cable. "Require pairing" is on by default. The CLI
  without `--pairing` keeps an old plain-TCP, unauthenticated door, for
  development only.
- The **remote door** (Remote Access, off by default, TCP port 7455): for
  reaching the Mac through your own VPN (Tailscale, WireGuard) or a port forward.
  Paired devices only. No relay or hole punching.

Paired devices and the Mac's identity live in the keychain (the data-protection
keychain for the notarized download, the login keychain for self-built copies).
**Direct Wireless Connection** (off by default) also listens on peer-to-peer
Wi-Fi (AWDL) for a device that shares no network with the Mac.

**Wire protocol.** Each message is a 14-byte header plus a payload; kinds are
listed in `Sources/StreamProtocol/StreamMessage.swift`. ALPN `sill/1` for
sessions, `sill-pair/1` for a one-shot pairing connection. Roughly:
- Video: 0 parameter sets, 1 HEVC frame.
- Catalog: 2 window list, 3 thumbnail, 4 app icon, 5 app list; 6 select source, 7 launch app.
- Input and view: 8 input (pointer, scroll, key, text), 9 viewport, 15 window command, 28 trackpad gesture.
- Health: 10/11 ping/pong, 12 client stats, 13 tick (keeps the device's Wi-Fi awake).
- Pointer: 14 cursor shape, 26 the Mac's pointer position.
- Settings: 16 host settings (host to device), 17 change settings (device to host).
- Identity and pairing: 18 signed Mac info, 19/20 pair request/result, 21 "show your pairing code", 22 goodbye, 23 hello (device's first message, version and build).
- Menus: 24 menu bar, 25 press item, 27 fetch menu.
- Clipboard: 32 (both ways, text only for now).
- 255 is "unknown", never sent. 29–31 are kept free on main (29 for audio, 30–31 for PR #66). See section 6 for the numbers open PRs are claiming.

**iOS client.** Browses Bonjour (and nearby AWDL on request), lists saved Macs,
reconnects by itself after drops or sleep, decodes into an
AVSampleBufferDisplayLayer, and has separate layouts for iPad, iPhone upright
(picture on top, buttons, keys and trackpad below), and each iPhone Duo pose
(nothing interactive sits on the fold). The bar shows live window thumbnails, an
Apps drawer (a searchable list, deliberately not an icon grid, for App Review
guideline 4.2.7), the Mac's menus, Aa (text scale), Keyboard, Desktop and
Settings.

**Menu bar app.** `Sill.app` has no Dock icon; its menu shows connected devices
with frame rate, frame age, round trip and route, and holds the main toggles.
Settings has General, Streaming, Devices and Remote Access panes. It checks
GitHub Releases once a day for a newer version and only points at the release
page; it never downloads anything. Logs: `~/Library/Logs/Sill/Sill.log`.

**Virtual display.** Optional (off by default). Uses the private
`CGVirtualDisplay` API to give the streamed window its own HiDPI display at the
device's size, so text is crisp and the window keeps repainting. Every failure
falls back to capturing the real window. Without it, Aa resizes the real window
over Accessibility, and Sill puts the window back to its own frame when the
stream stops. The private API is why the Mac app can never be on the Mac App
Store.

**Input.** Taps, drags, scroll with momentum, the on-screen trackpad, Pencil as
the pointer, typed text and keys become CGEvents (needs Accessibility).
Three-finger swipes and pinches become the Mac's own Mission Control / App
Exposé / Spaces shortcuts. A hardware keyboard on the device types on the Mac
directly. The host tracks which modifiers each device has held so none get stuck.

**Remote access and "away" behaviour.** A device away from home starts on a
lower away quality, the host paces remote frames by unsent bytes so a keyframe
cannot starve the link, `LinkJudge` tells the device when the link cannot keep
up, and a session moves back to the home path by itself when it can.

## 4. Build, run and test

**Toolchain.** Xcode 27 for the Mac side; **Xcode 27.1** (or a later 27) for the
iOS app, because it uses the iOS 27.1 SDK for the Duo's hinge. Deployment targets
are **macOS 14+** and **iOS 17+**. Select Xcode as the developer directory and
accept its license; with only Command Line Tools, add `--build-system native`.

Day-to-day commands:

```sh
swift build -c release                                  # build host, CLI, menu bar app, probes

swift run -c release SillHost                           # CLI host; nothing streams until a device picks a window
swift run -c release SillHost Safari                    # preselect a matching window
swift run -c release SillHost --synthetic               # Desktop is a test pattern; no Screen Recording needed
swift run -c release SillHost --pairing                 # TLS home door with pairing, like Sill.app (prints code)
swift run -c release SillHost --virtual-display         # stream from a private HiDPI virtual display
swift run -c release SillHost --encoder-selftest        # is the hardware encoder alive?

Scripts/make-app.sh                                     # build and sign .build/Sill.app
Scripts/make-app.sh --install --open                    # replace /Applications/Sill.app and launch it

python3 Scripts/sillclient.py PORT 8 desktop            # a fake device against a local host

Tests/checks/run-all.sh                                 # every pure check, as CI runs them (~5 min)
Tests/checks/run-all.sh policy fence                    # only some checks
Tests/checks/run-all.sh --mutants                       # also mutation tests (over an hour)

python3 -m http.server 8000 --directory site            # the website at http://localhost:8000
```

iOS app: open `iOSClient/Sill.xcodeproj`, pick your team, run on a device on the
same Wi-Fi. CI's headless build is:

```sh
xcodebuild -project iOSClient/Sill.xcodeproj -scheme Sill \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
```

Things to know:
- A new iOS source file needs its four `project.pbxproj` entries added by hand.
- Permissions: the CLI's Screen Recording/Accessibility belong to Terminal; Sill.app's to itself. With no Apple Development identity, `make-app.sh` signs ad hoc and you re-grant permissions after every rebuild.
- Synthetic hosts don't advertise on Bonjour; reach them with `sillclient.py` or the simulator's `-SillConnect` launch argument (`lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` finds the port).
- Settings: `defaults read <Sill.app bundle ID>`; a launch argument like `-maxFPS 60` overrides one for a run.
- `SILL_UNIVERSAL=1 Scripts/make-app.sh` builds arm64 + x86_64; the Intel slice has never streamed on a real Intel Mac.
- Releases: `Scripts/release.sh` (notarized dmg + zip, needs a Developer ID identity and notary profile) and `Scripts/release-ios.sh`; see `docs/release-checklist.md`.

The full list of flags, test hooks (`SILL_TEST_*` environment variables,
`-Sill*` launch arguments, the iOS debug harness) and headless recipes is in
**CLAUDE.md, "Build and run"**, with friendlier explanations in
`docs/DEVELOPMENT.md`, "Test tools".

## 5. Feature status

"On main" means merged after the 0.5.1 release and not yet shipped to users.
PR links are to Saffsanity/sill.

| Feature | Status | Plan | Upstream PR / branch |
|---|---|---|---|
| Per-window capture + HEVC streaming, Desktop source | Shipped | `BRIEF.md` | Milestones 1–2 |
| Sill.app menu bar host | Shipped | `menu-bar-app-plan.md` | [Saffsanity/sill#2](https://github.com/Saffsanity/sill/pull/2), [#3](https://github.com/Saffsanity/sill/pull/3) |
| Device changes Mac settings (kinds 16/17) | Shipped | `ipad-host-settings-plan.md` | [Saffsanity/sill#4](https://github.com/Saffsanity/sill/pull/4) |
| Direct Wireless Connection (AWDL) | Shipped | `direct-wireless-plan.md` | [Saffsanity/sill#5](https://github.com/Saffsanity/sill/pull/5), [#6](https://github.com/Saffsanity/sill/pull/6) |
| Quality presets | Shipped | none | [Saffsanity/sill#8](https://github.com/Saffsanity/sill/pull/8) |
| Encoder hang recovery, slow-state recycling | Shipped | none | [Saffsanity/sill#11](https://github.com/Saffsanity/sill/pull/11), [#20](https://github.com/Saffsanity/sill/pull/20) |
| Remote access (bring your own VPN / port forward) | Shipped | `remote-access-plan.md` | [Saffsanity/sill#13](https://github.com/Saffsanity/sill/pull/13) |
| Update check + "update your device" notice | Shipped | `update-notice-plan.md` | [Saffsanity/sill#18](https://github.com/Saffsanity/sill/pull/18) |
| iPhone portrait layout | Shipped | `iphone-portrait-plan.md` | [Saffsanity/sill#30](https://github.com/Saffsanity/sill/pull/30) |
| The Mac's pointer shown on the device | Shipped | `pointer-visibility-plan.md` | [Saffsanity/sill#31](https://github.com/Saffsanity/sill/pull/31) |
| Away from home: pacing, away quality, link judge | Shipped | `remote-bundle-plan.md` | [Saffsanity/sill#34](https://github.com/Saffsanity/sill/pull/34), [#39](https://github.com/Saffsanity/sill/pull/39) |
| First-run tour | Shipped | `first-run-walkthrough-plan.md` | [Saffsanity/sill#35](https://github.com/Saffsanity/sill/pull/35) |
| The Mac's menu bar on the device | Shipped | `menu-bar-plan.md` | [Saffsanity/sill#36](https://github.com/Saffsanity/sill/pull/36) |
| Pairing at home (TLS, ask/QR/code/cable) | Shipped | `home-pairing-plan.md` | [Saffsanity/sill#37](https://github.com/Saffsanity/sill/pull/37) |
| Three-finger trackpad gestures (Tier 1) | Shipped; Tier 2 not built | `trackpad-gestures-plan.md` | [Saffsanity/sill#38](https://github.com/Saffsanity/sill/pull/38) |
| Keychain hardening | Shipped | `keychain-plan.md` | [Saffsanity/sill#42](https://github.com/Saffsanity/sill/pull/42) |
| iPhone Duo layouts (iOS 27.1 SDK) | Shipped in 0.5.1 | `iphone-duo-plan.md` | [Saffsanity/sill#47](https://github.com/Saffsanity/sill/pull/47) |
| Settings window fits small screens | On main | `settings-window-plan.md` | [Saffsanity/sill#74](https://github.com/Saffsanity/sill/pull/74) |
| Windows go back to their own frame | On main | `restore-window-frames-plan.md` | [Saffsanity/sill#75](https://github.com/Saffsanity/sill/pull/75) |
| Reconnect after hours idle | On main | `reconnect-after-sleep-plan.md` | [Saffsanity/sill#77](https://github.com/Saffsanity/sill/pull/77) |
| Clipboard both ways (text) | On main; images reserved for later | `clipboard-plan.md` | [Saffsanity/sill#78](https://github.com/Saffsanity/sill/pull/78) |
| Larger Picture on iPhone upright | On main | `larger-picture-plan.md` | [Saffsanity/sill#79](https://github.com/Saffsanity/sill/pull/79) |
| Hardware keyboard and trackpad on the device | On main | `hardware-keyboard-plan.md` | [Saffsanity/sill#80](https://github.com/Saffsanity/sill/pull/80) |
| Homebrew cask | On main | none | [Saffsanity/sill#85](https://github.com/Saffsanity/sill/pull/85) |
| Universal (Intel) Mac build | On main, opt-in, untested on real Intel | none | [Saffsanity/sill#88](https://github.com/Saffsanity/sill/pull/88), [#87](https://github.com/Saffsanity/sill/pull/87) |
| Tailscale (App Store build) address listing | On main | none | [Saffsanity/sill#98](https://github.com/Saffsanity/sill/pull/98) |
| Apps in subfolders; Shift+Return/Tab | On main | none | [Saffsanity/sill#136](https://github.com/Saffsanity/sill/pull/136), [#110](https://github.com/Saffsanity/sill/pull/110) |
| Fit picked window to the device by default | In progress (upstream) | `fit-by-default-plan.md` (on branch) | branch `fit-by-default` |
| Desktop cycles through the Mac's displays | In progress (upstream) | `display-stepping-plan.md` (on branch) | branch `display-stepping`, [Saffsanity/sill#173](https://github.com/Saffsanity/sill/pull/173) |
| Mac's sound on the device (beta) | In progress (upstream) | `audio-plan.md` (on branch) | branch `wip/audio`, [Saffsanity/sill#94](https://github.com/Saffsanity/sill/pull/94) |
| Apple Pencil pressure and tilt | In progress (upstream) | `pencil-pressure-plan.md` (on branch) | branch `pencil-pressure-rebased`, [Saffsanity/sill#175](https://github.com/Saffsanity/sill/pull/175) |
| Adjustable thumbnail hold | In progress (upstream) | `thumbnail-hold-plan.md` (on branch) | branch `thumbnail-hold`, [Saffsanity/sill#164](https://github.com/Saffsanity/sill/pull/164) |
| Other upstream finishing work | In progress | none | see section 6 |
| iCloud auto-pairing (same Apple Account) | Planned (milestone 5), not started | `BRIEF.md` | none |
| UDP/QUIC transport | Planned; external PR open | none | [Saffsanity/sill#124](https://github.com/Saffsanity/sill/pull/124) |
| Clipboard images | Planned (field reserved) | `clipboard-plan.md` | none |
| Hide the top bar | Decided (device toggle, shake to bring back), not built | none | [issue #92](https://github.com/Saffsanity/sill/issues/92), [Saffsanity/sill#161](https://github.com/Saffsanity/sill/pull/161) |
| Pinch to zoom on the picture | Decided, external PR needs changes | none | [issue #65](https://github.com/Saffsanity/sill/issues/65), [Saffsanity/sill#150](https://github.com/Saffsanity/sill/pull/150) |
| Multi-window, hole punching, layout customization | Out of scope for v1 | `BRIEF.md` | none |

## 6. Upstream work in progress

Two kinds of activity are going on upstream. First, the maintainer (Noah,
GitHub `Saffsanity`) runs agent-driven branches: some are his own features,
some finish contributors' PRs by adding commits on top. Second, there is a wave
of ~49 open outside PRs, most from the week after launch. Nearly all of
Noah's branches were **paused mid-run on 2026-10-20 at 09:35** (several WIP
commits say "an agent was cut off; see the handoff"). That handoff lives
outside the repository, so what each branch has left is only what its commit
messages and `CLAUDE.md` entry say. The last commit on `upstream/main` is
2026-10-20 (4d990e9).

### The maintainer's live branches

- **Fit by default** (`upstream/fit-by-default`, 4 commits, no PR; [issue #70](https://github.com/Saffsanity/sill/issues/70)). In regular mode, a picked window is sized to the device's panel at 1× even before Aa is touched, with a new Mac setting "Fit windows to the device's screen" (on), a CLI `--no-fit`, and an optional `fitsPanel` field in kind 16. It also takes the one-line `scalesToFit` fix from closed PR #149. Code, checks and docs are committed, but the CLAUDE.md entry's "Verified" and "Untested" lines are still placeholders, so verification had not been written up.
- **Desktop display stepping** (`upstream/display-stepping`, 16 commits; [issue #91](https://github.com/Saffsanity/sill/issues/91)). The Desktop button shows which display it is on, and a tap moves to the next one. It runs alongside contributor PR [Saffsanity/sill#173](https://github.com/Saffsanity/sill/pull/173) on the same issue. Builds and most checks pass. Still to do: 7 harness screenshots that differ slightly from main, live tests with two displays, 13 mutants, docs, and another merge of main.
- **Audio beta** (`upstream/wip/audio`, 61 commits; finishing [Saffsanity/sill#94](https://github.com/Saffsanity/sill/pull/94), [issue #83](https://github.com/Saffsanity/sill/issues/83)). Plays the Mac's sound on the device with AAC-ELD on **kind 43**, behind "Send Audio", off by default. This is the largest branch (about 10k lines). Two mutant runs were left to finish. Note that BRIEF/CLAUDE.md still list audio as out of scope for v1, so upstream has clearly changed its mind.
- **Apple Pencil pressure and tilt** (`upstream/pencil-pressure-rebased`; [Saffsanity/sill#175](https://github.com/Saffsanity/sill/pull/175), [issue #81](https://github.com/Saffsanity/sill/issues/81)). The Pencil goes to the Mac as a tablet pen on **kind 45**. Built and passing. Left: finish the clipboard mutants, a decision on #175's extra hover-cursor kind (46), and testing in real drawing apps (Hunter's P0–P10).
- **Audit fixes** (`upstream/wip/fix93`; [Saffsanity/sill#93](https://github.com/Saffsanity/sill/pull/93), [issue #101](https://github.com/Saffsanity/sill/issues/101)). Fixes a Close that stalled the host and a picture left blank after an interruption, using a new device-to-host **keyframe request, kind 44**. This branch reports itself verified (all 47 checks, mutants), so it looks close to merging.
- **Goodbye on sleep/shutdown** (`upstream/wip/fix100`; [Saffsanity/sill#100](https://github.com/Saffsanity/sill/pull/100), [issue #105](https://github.com/Saffsanity/sill/issues/105)). The Mac tells devices when it sleeps, restarts or shuts down. Builds pass. It is waiting on Noah's real sleep, restart and shutdown tests before the user-facing text goes in.
- **Wake the display** (`upstream/wip/fix151`; [Saffsanity/sill#151](https://github.com/Saffsanity/sill/pull/151), [issue #134](https://github.com/Saffsanity/sill/issues/134)). Fixes black windows when the Mac's display is asleep, by declaring user activity when a device connects rather than holding the display on. Mostly docs commits now.
- **Connect-screen tiles** (`upstream/wip/tiles`; [Saffsanity/sill#117](https://github.com/Saffsanity/sill/pull/117)). Saved Macs as tiles showing each Mac's last picture, with groups. Verified apart from two live checks; the plan is to push the result to the contributor's branch.
- **Chinese input and dictation** (`upstream/wip/pr147`; [Saffsanity/sill#147](https://github.com/Saffsanity/sill/pull/147), [issue #138](https://github.com/Saffsanity/sill/issues/138)). Marked-text composition (Zhuyin and similar) and dictation reach the Mac. Paused with uncommitted work saved as-is. The PR conflicts with main.
- **Reverse scrolling** (`upstream/wip/reverse`; [Saffsanity/sill#159](https://github.com/Saffsanity/sill/pull/159), [issue #143](https://github.com/Saffsanity/sill/issues/143)). A small device switch; the branch has docs and main merged in. Small and nearly done.
- **Thumbnail hold** (`upstream/thumbnail-hold`; [issue #113](https://github.com/Saffsanity/sill/issues/113)). The long-press to show window controls becomes adjustable (1–5 s, default 1 s) and shows a pressed state. It competes with contributor PR [Saffsanity/sill#164](https://github.com/Saffsanity/sill/pull/164) (0.5 s default); which one lands is Noah's call.
- **Device rig** ([Saffsanity/sill#166](https://github.com/Saffsanity/sill/pull/166), test only): an XCUITest rig that drives Sill on a plugged-in iPhone or iPad.
- **iOS 16 evaluation** (`upstream/ios16-smallest`, local evaluation of [Saffsanity/sill#155](https://github.com/Saffsanity/sill/pull/155)). Status unclear. Several other open PRs use iOS 17-only APIs.

### Notable open outside PRs (not yet taken up by upstream)

- Settings panel additions from addhumal: Picture Smoothing [#107](https://github.com/Saffsanity/sill/pull/107), Capture Screen [#96](https://github.com/Saffsanity/sill/pull/96), Connection Information [#95](https://github.com/Saffsanity/sill/pull/95), Trackpad Speed [#172](https://github.com/Saffsanity/sill/pull/172), Spotlight for saved Macs [#99](https://github.com/Saffsanity/sill/pull/99). Upstream's review notes say these touch the same spots in `HostSettingsPanel.swift` and `HEVCDisplayView.swift`, so they need an agreed order.
- Device features from addhumal: send files [#189](https://github.com/Saffsanity/sill/pull/189), microphone [#191](https://github.com/Saffsanity/sill/pull/191), camera [#193](https://github.com/Saffsanity/sill/pull/193), Privacy Mode for remote sessions [#184](https://github.com/Saffsanity/sill/pull/184), headless `--pair-code` [#187](https://github.com/Saffsanity/sill/pull/187), iPad landscape trackpad [#185](https://github.com/Saffsanity/sill/pull/185), key repeat fix [#163](https://github.com/Saffsanity/sill/pull/163).
- Small input/UX PRs: Aa Off detent [#181](https://github.com/Saffsanity/sill/pull/181), Aim Without Clicking [#174](https://github.com/Saffsanity/sill/pull/174), Left Option as Command [#183](https://github.com/Saffsanity/sill/pull/183), follow new windows [#182](https://github.com/Saffsanity/sill/pull/182), new windows first in the bar [#111](https://github.com/Saffsanity/sill/pull/111) (conflicting), remote-dial host classification [#194](https://github.com/Saffsanity/sill/pull/194).
- Host/transport: QUIC beside TCP [#124](https://github.com/Saffsanity/sill/pull/124); encoder rate caps [#122](https://github.com/Saffsanity/sill/pull/122), [#71](https://github.com/Saffsanity/sill/pull/71).
- Other platforms. These are big and they compete with each other; upstream's review notes say at most one Mac-client design can land. Mac viewer [#66](https://github.com/Saffsanity/sill/pull/66) (with [#72](https://github.com/Saffsanity/sill/pull/72), [#73](https://github.com/Saffsanity/sill/pull/73), all conflicting) vs [#128](https://github.com/Saffsanity/sill/pull/128) (Mac viewer plus Rust Windows/Linux hosts); a 5-part Android/Windows/Linux series [#167](https://github.com/Saffsanity/sill/pull/167)–[#171](https://github.com/Saffsanity/sill/pull/171) (about 30–40k lines each); Android draft [#89](https://github.com/Saffsanity/sill/pull/89); visionOS [#158](https://github.com/Saffsanity/sill/pull/158) (conflicting, multi-window host).

### Before you pick something up

- **Wire kind numbers are contested.** Main uses 0–28, 32 and 255, and keeps 29–31 free. Open work claims: 33 (#158 `editableFocus`, and also audio in #66), 34–42 (#66's family, with 34/35 matching #189's file kinds), 43 audio (#94), 44 keyframe request (#93), 45 **both** the Pencil (#175) and the microphone (#191), 46 **both** the Pencil hover cursor (#175) and the camera (#193). Kind numbers are never reused, so if you add a message, pick a number above 46 or coordinate upstream first.
- **Expect rebases.** Upstream merges main into its branches often. Branches touching `StreamClient.swift`, `HostSettingsPanel.swift`, `HEVCDisplayView.swift` and `StreamCoordinator.swift` collide with each other. Check `gh pr view N --comments` for upstream's per-PR overlap notes ("From a pass over all the open pull requests").
- **Upstream's finishing branches are pushed as `wip/*`**, not to the contributor's branch. If you build on one, start from the upstream branch, not the PR head.
- **Good first picks:** Reverse scrolling (#159 / `wip/reverse`) and the audit fixes (#93 / `wip/fix93`) look closest to done. Fit-by-default is a self-contained, high-value change with its plan written. The Settings panel PRs are small but need ordering.
- The iPhone Duo goes on sale on **2026-10-23**, so Duo layout bugs are likely to be upstream's priority soon.

## 7. Rules worth keeping

From `CLAUDE.md` "Conventions", "Decisions already made" and "Compatibility floor":

- **Swift and Apple frameworks only.** No third-party dependencies unless `BRIEF.md` explicitly allows one.
- **Zero operating costs, no servers.** No relay, no account system, no backend. Remote access means the user's own VPN or port forward. The only network call that isn't to the user's own devices is the daily GitHub Releases check.
- **HEVC, real time, no B-frames.** AV1 is out (no hardware encode on Apple silicon).
- **Latency beats quality.** Drop frames rather than queue them. The target is under ~60 ms on a LAN.
- **Free, tip jar, open source (Apache-2.0).** Not paid, not a subscription.
- **Native feel is the bar**: iOS conventions and Duo-aware layouts. Never put controls across the Duo's fold. The Apps drawer stays a searchable list (App Store guideline 4.2.7).
- **Mac app is Developer ID only**, because of the private virtual-display API and Accessibility-based input. Every private-API path needs a real-window fallback.
- **Keep decision logic pure and checked.** New rules go in a pure file with a folder in `Tests/checks` (and mutants), as the existing features do.
- **Don't add features the current milestone doesn't need**; v1 scope excluded hole punching, multi-window and layout customization (audio was also excluded, but upstream now has an audio beta in progress).
- **Compatibility floor, in brief.** Shipped apps must keep working with each other across versions:
  - Never renumber or reuse a message kind; never rename or retype a field; new fields are optional; never add a case to an enum an older peer decodes.
  - Keep the 14-byte header, ALPNs `sill/1` and `sill-pair/1` (a future `sill/2` goes beside them, never instead), the TLS home door with pairing, and the pairing methods and reasons as 1.0 has them.
  - New capabilities are announced by the host (for example `WindowList.gestures`, `WindowList.clipboard`), and a device sends the new kind only to a host that advertised it.
  - A device that is too old is refused with a kind 22 "update" goodbye, never served something wrong. `SillProtocol.current` (1) rises only for a change an older peer can't skip.

## 8. Fork notes

This fork is owned by GitHub user **gabrieldrl** (`origin` = gabrieldrl/sill;
the original is the `upstream` remote, Saffsanity/sill). It uses its own bundle
IDs, signing team, Bonjour service type and update feed, so its builds can be
installed beside the official Sill without sharing permissions, keychain items or
discovery, and its Sill.app never offers upstream's releases as updates.

| What | Upstream | This fork |
|---|---|---|
| iOS bundle ID | `me.saffer.sill` | `com.gabrieldrl.sill` |
| Mac bundle ID (and its `defaults` domain) | `me.saffer.sill.mac` | `com.gabrieldrl.sill.mac` |
| Apple team | `9B2KKVM937` (Noah) | `JF8R4AVC2H` (Gabriel Lam, Personal Team) |
| Bonjour service type | `_sill._tcp` | `_sillgdl._tcp` |
| Pairing link scheme | `sill://pair` | `sillgdl://pair` |
| Update feed / release repo | Saffsanity/sill | gabrieldrl/sill |
| Keychain tags, pasteboard and menu identifiers | `me.saffer.sill.*` | `com.gabrieldrl.sill.*` |

What that means in practice:
- **The fork and the official apps don't see each other.** Your iOS build finds only your Mac
  build, and the reverse. Upstream's `CLAUDE.md` and `docs/` still say `me.saffer.sill.mac` and
  `_sill._tcp`: read those as this fork's values.
- **Free personal team.** Device builds sign with a free provisioning profile, which iOS makes you
  re-install every 7 days. A free team has no App Store / TestFlight and no Developer ID, so
  `Scripts/release.sh` and `Scripts/release-ios.sh` won't work until you join the paid Apple
  Developer Program.
- **The update check needs a public repo.** Sill.app reads
  `api.github.com/repos/gabrieldrl/sill/releases/latest` without signing in, which a private repo
  answers with 404. The check stays quiet until the repo is public and has a release.
- **Build outside `~/Documents` for device builds.** A signed iOS build whose build folder is inside
  this checkout (e.g. `-derivedDataPath .build/...`) fails with "resource fork, Finder information,
  or similar detritus not allowed". Xcode's default folder (`~/Library/Developer/Xcode/DerivedData`)
  is fine.
- **Branches:** `main` is upstream's `main` at 4d990e9 plus this fork's commits (from 80cb797, the
  fork setup). Develop on `dev`, or on feature branches off it, and merge into `main` when a change
  is done. To take upstream's work: `git fetch upstream`, then merge
  `upstream/main` or an `upstream/<branch>`. Pushing to `upstream` is disabled in this checkout.
- Left as upstream's: the website in `site/`, the iOS app's links to getsill.app, the app name
  "Sill" and its icon, `.github/FUNDING.yml` and the issue templates.

Places those identifiers live upstream (worth checking after any merge from
upstream): `Packaging/Info.plist` (Mac bundle ID), the iOS project's
`PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM`, the `NSBonjourServices` and
service-type strings (`_sill._tcp`), `UpdatePolicy.feed` in
`Sources/SillMenuBar/UpdatePolicy.swift`, the keychain service names, and the
`SILL_RELEASE_REPO` used by `Scripts/release.sh`.
