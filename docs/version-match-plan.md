# The Mac and the device on the same Oriel

Gabriel, 2026-10-23: "something quickly that checks both mac and client are running the same version
and if not, prompts either on mac, or app that the other or this one needs updating".

## What it does

Both sides already know both versions: the device's hello (kind 23) carries `appVersion`, and every
window list carries the Mac's `hostVersion`. Nothing new goes on the wire.

- `VersionMatch` (Sources/StreamProtocol/VersionMatch.swift, pure, checked by
  `Tests/checks/version-match` with 10 mutants): the verdict `same`, `updateMac`, `updateDevice` or
  `unknown`, from the two marketing versions as SillVersion reads them (builds ignored), and the words
  each side shows. A side without a version (SillHost, an unbundled Mac app's "dev", a Mac before
  2026-09-25) says nothing.
- The Mac: each device's hello version goes into `HostStatusSnapshot.Device.appVersion`, the Mac's own
  into `HostStatusSnapshot.hostVersion`. The status card shows a line under a device on another Oriel
  ("Update Oriel on it to 0.2", "Has Oriel 0.2: update this Mac"). A device newer than the Mac also
  puts the attention badge on the glyph and "Update Oriel on This Mac…" in the menu, which opens the
  latest release's page. An older device is only news there, as the older-device item always was: the
  device says so itself.
- The device: the new stream screen (DesktopScreen) shows a glass pill at the picture's top, "Update
  Oriel on this iPad: ‹Mac› has 0.2." or "Update Oriel on ‹Mac›: this iPad has 0.2."; a tap puts it
  away for the session. The classic StreamScreen does not show it.

Only shown, never acted on: devices and Macs of different versions still connect, as the compatibility
floor requires.

## Results

- `Tests/checks/version-match`: 25 checks, 10 of 10 mutants caught. The 21 checks that compile
  StreamProtocol or the changed files pass.
- The Mac's previews (`-SillRenderPreviews`): the sample `versions-differ` (an older iPad and a newer
  iPhone on a 0.2.0 Mac) gives both card lines, the badge and the menu item.
- Simulator, live: a loopback synthetic SillHost built for the test to say 0.2.0 (not committed) and
  the iPad simulator with `-SillHelloVersion 0.1.0`: the host logged the hello's 0.1.0, the pill said
  "Update Oriel on this iPad: Gabriel’s MacBook Pro has 0.2.", and a tap put it away.
- The layout harness (`-SillLayout`) spins at 100% CPU with a white screen in MorphingPicker's frame
  reporting, at HEAD before this change too, so the mock's `-SillMockHostVersion` is unseen there.

## Untested on a device

Oriel.app and the iPad on different releases: the card line, the menu item opening the release page,
and the pill on the iPad.
