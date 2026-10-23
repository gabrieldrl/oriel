# A simple Settings window on the Mac (2026-10-23)

Gabriel's ask: Settings becomes General, Devices and Permissions, with short text throughout.

## What it has now

- **General:**
  - Launch at login.
  - The Mac's name, with Change… opening Sharing settings.
  - Share clipboard with devices (on by default).
  - Check for updates automatically.
  - Remote Access: the VPNs this Mac has and what to do. The port shows only while another app
    holds it, with Change….
  - Sleep, with Open Energy Settings….
  - Quit Oriel, with the version under it.
- **Devices:** the paired devices, each with Remove (unpairs it) and a hidden double-click rename.
  It has no Require pairing switch and no Pair iPhone or iPad… button: pairing starts on the device,
  over the USB cable by itself, or with a code the Mac shows when the device asks.
- **Permissions:** Screen Recording and Accessibility, Local Network when devices can't find the
  Mac, and Relaunch once Screen Recording is given.

## What went

- **The tabs:**
  - Streaming and Virtual Display: each device sets them, through kind 16.
  - Remote Access: it is always on, and General has its section.
- **From General:**
  - Running from.
  - Direct Wireless Connection: the device's Settings panel has it.
  - Show Log… and Reveal Log File.

## Always on

Oriel.app turns Require pairing and Remote Access back on at launch when a Mac had either off.
`AppModel.launchRequirePairing` saves Require pairing beside the trust list. `AppModel.start` sets
`remoteAccess`. With no switch left, a Mac that had one off would otherwise stay that way for good.

The CLI and the bare SillMenuBar binary keep both as they were (`-requirePairing`, `-SillSetAfter`),
for the tests.

## Text

The clipboard's footnote, its warnings and hints, and the update check's footnote are each one or
two short sentences now. Their checks (`Tests/checks/clipboard`, `Tests/checks/update-policy`) pin
the new words. The clipboard mutant that matched the warning had still said "Sill", so it now
matches again.

## Gaps

- **The new stream screen (DesktopScreen) has no way to set some of what the removed tabs set:**
  - Prioritize encoding speed.
  - The single-window virtual display.
  - Direct Wireless Connection.

  Only the classic StreamScreen's Settings panel has them. A Mac keeps whatever it had saved.
- **Settings no longer says when the software encoder is in use.**

## Untested

Only the rendered previews (`-SillRenderPreviews`) have been looked at. Still to try in Oriel.app:

- The window's height per tab.
- A Mac that had Require pairing or Remote Access off, launched once.
- Remove on a real device.
