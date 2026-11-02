# Extended Use: the Mac kept awake, lid closed too

Gabriel, 2026-11-02: "an extended in use mode which will always keep mac awake when closing the lid.
this can be configured on either the mac or the ios client via a new settings page for each mac. it
will be off by default and be configurable eg. always, only when plugged in." The warning for Always
is one line: it increases heat and battery use.

Why: a Mac asleep can't be reached. Away (Tailscale) nothing wakes it, and the card says "Offline".
At home only a Bonjour Sleep Proxy (an Apple TV, a HomePod) wakes it, and a dial gives up after 5 s.
Oriel already keeps the Mac from idle sleep while a device is connected from away, and its display
from sleeping while anything streams (AppModel's `holdAppNapOff`, DisplayWake), but nothing stops
the lid's sleep, and nothing keeps a Mac awake for a device not yet connected.

## What it does

- **Extended Use**, one setting of the Mac's: **Off** (the default), **Always**, **When Plugged In**.
  While it holds, the Mac doesn't sleep: not when idle, not when its lid closes. Its displays still
  sleep as they would. Off puts sleep back as it was.
- When Plugged In holds only while the Mac runs on its power adapter: the charger out lets it sleep
  (at once with the lid closed), the charger back in holds again.
- A Mac without a battery has no When Plugged In: Off and Always.
- Always says, under the choice, "Increases heat and battery use." (on a Mac with a battery).
- Set on the Mac (Settings › General) or from a device (a settings page for each Mac). It is the
  Mac's one setting: whichever changes it last wins, and every connected device and the Mac's pane
  show the same value at once.

## How

1. **The lid needs root.** An app's power assertions stop idle sleep, never the lid's. `pmset -a
   disablesleep 1` (the SleepDisabled setting) stops both, and needs root. So Oriel.app carries a
   launch daemon, SillAwake (`Sources/SillAwake`), registered with `SMAppService.daemon`. macOS asks
   once, in System Settings › General › Login Items ("Allow in the Background"); until then the
   pane says so with a button there, and a device's page says the Mac is waiting for it.
2. **The daemon** listens on the Mach service `com.gabrieldrl.sill.mac.awake`
   (`Packaging/LaunchDaemons/com.gabrieldrl.sill.mac.awake.plist`, in the bundle at
   `Contents/Library/LaunchDaemons`; the executable at `Contents/MacOS/SillAwake`). It takes
   connections only from code signed as `com.gabrieldrl.sill.mac` by team JF8R4AVC2H
   (`setConnectionCodeSigningRequirement`). One call, `hold(on)`. While any connection holds,
   SleepDisabled is 1; when none does, 0.
3. **Never left on.** The daemon lets go when Oriel's connection goes: Oriel quitting, crashing or
   killed. It writes a marker (`/Library/Application Support/Sill/awake-held`) while it holds, and at
   its own start (RunAtLoad: every boot, every relaunch) a marker left behind puts SleepDisabled back
   to 0. A SleepDisabled the user set by hand, with no marker, is never touched.
4. **The Mac's side** (`Sources/SillHost/KeepAwake/`): `KeepAwakePolicy`, pure
   (`Tests/checks/keep-awake`): whether to hold from the mode and the power source, and what the
   daemon's registration says to show. `HostKeepAwake`: the mode in defaults (`Sill.keepAwake`), the
   power source (IOPS notifications), the registration, the XPC connection, and the state to the
   devices. Available under the AppKit loop in a bundle that carries the daemon; a synthetic host
   keeps the state and touches nothing on this Mac; the CLI never offers it.
5. **The wire** (additive): `WindowList.keepAwake` 1; kind 56 `keepAwake`, JSON `KeepAwake` both
   ways (KeepAwake.swift). Device → host: `{"mode":"always"}` sets it (a mode this host doesn't know
   is ignored). Host → device: its state after each window list and whenever it changes, to every
   connection: `mode`, `awake` (held now), `battery` (whether When Plugged In means anything),
   `onPower`, and `problem` ("approval": waiting for Login Items; "unavailable": this build can't,
   e.g. signed ad hoc). A device sends kind 56 only to a host whose window list says `keepAwake` 1.
6. **The device's page for each Mac** (`MacSettingsScreen`): from a card's long-press menu and its
   chevron menu (Settings…), and from the ⓘ panel while connected (Mac Settings). Extended Use as a
   picker, the Always line, and a status line: "Keeping ‹Mac› awake", "Waiting for power",
   "Allow Oriel in Login Items on ‹Mac›". Connected to that Mac, a choice goes at once. Not
   connected, the page shows what the Mac last said; a choice is kept and sent at that Mac's next
   connection ("Oriel changes this on ‹Mac› when you next connect").

## Open questions, with the defaults taken

1. The name. Default: "Extended Use", Gabriel's own words, with a footer: "Keeps this Mac awake,
   even with its lid closed, so your devices can always connect."
2. A Mac without a battery. Default: Off and Always only, and no heat-and-battery line.
3. Unregister the daemon when set back to Off? Default: no. It holds nothing while Off, and
   unregistering would make macOS ask again next time.
4. A change made on a device while not connected. Default: kept and sent at the next connection
   (as the curtain's kept choice is); the Mac's own change in between loses to it, as the latest.
5. The lid closed with nothing but the built-in display: the Mac has no display left to stream.
   Default: nothing new here; the device's extended displays and external monitors still stream.
6. Battery: Always on battery with the lid closed can heat a laptop in a bag. Default: the one line,
   nothing more (Gabriel).

## Results

2026-11-02, built in a worktree at origin/dev (0.3.0):
- Wire: kind 56 and `WindowList.keepAwake` 1 (KeepAwake.swift); the pointer-control check's kind table
  and the curtain check's free kind moved on to 57.
- Mac: KeepAwakePolicy (pure; `Tests/checks/keep-awake`, 55 checks, 14 of 14 mutants caught),
  HostKeepAwake (the mode in `Sill.keepAwake`, the power source followed, the daemon registered
  with SMAppService on the first mode other than Off, asked over XPC), SillAwake (the daemon: `pmset
  -a disablesleep`, a hold per connection, a marker so a daemon that died holding lets go at its next
  start), Scripts/make-app.sh (the daemon in Contents/MacOS, its plist in
  Contents/Library/LaunchDaemons, signed with the bundle's identity). Settings › General's Sleep line
  became Extended Use; a build without the daemon keeps the old line. A mode the Mac does not offer
  (When Plugged In on a Mac without a battery) is answered with the state as it is.
- Device: StreamClient+KeepAwake (the last state kept per Mac, a change made away waiting for the
  next connection, both forgotten with the Mac), MacSettingsScreen, from a home card's menu and its
  chevron menu ("Settings") and the info panel's Mac Settings.
- Tried on this MacBook with the iPad: When Plugged In set from the iPad reached the Mac; the first
  register answered "Operation not permitted" (macOS asking in Login Items); once allowed, the Mac
  held (`pmset -g`: SleepDisabled 1), on its adapter. The first build asked the unregistered daemon
  to let go at launch while Off, which logged "did not answer"; a Mac left Off now never talks to it.

## Untested on a device (for Gabriel)

- The Mac's pane: its picker, Always's line and the approval line (seen only in code).
- Always, lid closed: the iPad still connects, from home and through Tailscale; a dial to the card
  works after minutes closed.
- When Plugged In: unplugged with the lid closed, the Mac sleeps; plugged back in, held again.
- Off: the lid's sleep comes back.
- Oriel quit, or killed (`kill -9`), while it holds: the Mac sleeps again (`pmset -g | grep
  SleepDisabled` reads 0).
- Changing it on the iPad shows on the Mac's pane at once, and the other way.
