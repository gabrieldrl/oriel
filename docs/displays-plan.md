# Extended displays

Gabriel, 2026-10-22: beside Apps, a Displays pill opens the same black sheet. It lists Primary (the
Mac's own display), the extended displays this device made, and a + that makes one more. Each is a
real display to macOS: arranged in System Settings › Displays, windows dragged onto it on the Mac,
and both come back when the device reconnects. The quick controls work on whatever streams.
Streaming a single app and the Mac's own display keep working as they did. One display at a time
per device (no Duo dual view). Disconnect is a global disconnect from this Mac: this device's
displays go at once.

## What the person sees

- **The pill**, after Apps in the quick controls: `display.2` and "Displays". It shows only for a
  Mac whose window list says `displays` 1. While the sheet is up it is lit, as Apps is: white, its symbol and text black.
- **The sheet**, a RisingSheet like Apps' and the key row's (one of the three at a time):
  - a header, with "The Mac couldn't add a display." after an add that made nothing;
  - a grid of previews at 16:10, the one streaming ringed in the accent colour. First Primary (its
    picture from the Mac every 5 s, else the home screen's picture of this Mac), then each extended
    display with its name and size, then a dashed tile with only a plus (its accessibility label "Add Display") while there is room for one more;
  - a tap streams that display and folds the sheet. Add Display makes one the size of the room this
    screen gives the picture and streams it. A display's context menu (and an accessibility action)
    removes it for good.
- **The size pill** (`aspectratio`), after Quality, only while an extended display streams: a menu of
  Default (the room this screen gives the picture, as a new display gets) and Match Primary (the Mac's
  own display's size and scale), the one in use ticked.
- **On the Mac** a new display is "Sill Display N" in System Settings › Displays, where it can be
  arranged, and windows can be dragged onto it. The status text shows "Display N" with the
  `display.2` symbol while it streams.
- **Reconnecting** brings back the device's displays, where they were arranged, with the windows that
  were on them, and streams the one it last showed.

## The rules

1. Up to 4 per device (`DisplayPolicy.maxPerDevice`); a new one takes the first free slot. Each is
   named for its place among this device's displays, the Mac's own being the first: "Display 2" to
   "Display 5" (`DisplayPolicy.name(slot:among:)`), renumbered whenever one comes or goes, so Primary and
   one more is always Display 2. macOS keeps the name it was made with until it is next made again.
2. A display belongs to the device that made it (its owner: its pairing fingerprint, else
   `name:` and its name). Other devices never see or stream it.
3. Its serial number is the owner's FNV-1a hash (top 24 bits, never 0) and the slot, so macOS sees
   the same display come back and keeps its arrangement. Vendor 0x5111 (Sill's, which keeps the app's
   own windows off it), product 0x0002.
4. Size: what the device asks for, each side clamped to 640…3840 and made even; 1366 × 1024 when it
   asks for none. Scale 2, 60 Hz.
   Match Primary (`resize` with `match: "primary"`): the main display's size in points and its scale
   (`DisplayPolicy.Primary`: 2 when it has 1.5 pixels a point or more, else 1), remembered in the slot
   (`matchesPrimary`, `scale`) and taken from the main display afresh each time it is made. Default
   (`resize` with a width and height) is the size rule above at scale 2. A resize takes the display
   without its windows' fall, waits 1 s, makes it again with the same serial (macOS keeps its
   arrangement; the windows are put back) and the stream goes on on it (`onRemade`). The stream's
   capture scale on a display is never more than its own pixels a point.
5. Endings (`DisplayPolicy.Ending`):
   - **Disconnect** (the device's `end`): its displays go now, remembered, with their windows.
   - **Lost** (the connection drops without `end`): they stay 30 s (`DisplayList.grace`); a
     reconnect inside that finds them as they were. After it, as Disconnect.
   - **Removed** (the device's `remove`): that display goes and is forgotten, windows not kept.
6. Windows: at an ending that keeps them, the windows on the display are recorded (app, title,
   offset, size); 1.5 s later where each fell (`fellTo`). When the display comes back, a window is
   put back (Accessibility) only if it is still where it fell, so one moved on the Mac meanwhile
   stays (`DisplayPolicy.returns`). A window is "on" a display when its centre is.
7. A display that streams and goes (removed, or by the system) hands the stream to the Mac's own
   display.
8. The memory is `~/Library/Application Support/Sill/Displays.json`. A synthetic host keeps none and
   never makes a display on this Mac: its displays are entries streamed as the test pattern.
9. Sill.app makes them only when the private CGVirtualDisplay API is there (`checkPrivateAPI`);
   SillHost --synthetic always lists them; the CLI otherwise never does.

## Settings per display

Gabriel, 2026-10-22: Resolution (Standard/Retina), Frame Rate and Quality are set per display, and the
device remembers them. They stay the Mac's settings (one stream for every device); the device keeps
what it wants for each display and asks for it when it starts showing that display. Device only, no
wire change (`iOSClient/DisplaySettingsMemory.swift`, pure, `Tests/checks/display-settings`; wired in
StreamClient+Displays).

1. Each display has a memory, per Mac: "Primary" for the Mac's own, an extended display by its name
   (`display <id>`: the id is the serial, the same each time for this device's slot). At home and away are kept apart ("Display 2 · away"),
   as the Mac keeps an away pair. `Sill.displaySettings.<macID>` in UserDefaults, as JSON.
2. A pick of any of the three (the quick controls or the Settings panel) changes that field in the
   memory of the display showing.
3. When this device asks for a display (a tap in the sheet, a new display, the connection's first pick),
   once the Mac's settings and its display list are in, the fields that differ go to the Mac through the
   settings ledger. A display shown for the first time sends nothing and keeps what the Mac shows then.
   Only values the Mac offers go: a Custom bitrate set by hand on the Mac is never asked for.
4. A window keeps the settings as they are: it has no memory, and a pick while one streams is kept for
   no display.
5. Only what this device asks for brings settings back: another device switching the shared stream, or
   the Mac falling back to its own display, does not. Removing the display showing does bring Primary's back.
6. Removing a display forgets its settings, so a new display in its slot starts afresh.
7. Only with a Mac that makes extended displays; with any other nothing is kept or sent, as before.

## The wire (additive)

- `StreamSource.display(UInt32)`, a new case, sent only to a host whose window list says
  `displays` 1. A host lists one as `active: .desktop` with `showing: <id>`, so an older device reads
  the Desktop (`WindowList.source` puts them together).
- `WindowList.displays: Int?` (1: this host makes extended displays) and `showing: UInt32?`.
- **Kind 49 `displays`**, host → a subscribed device: `DisplayList {displays: [{id, name, width,
  height}], max, problem}` (`problem` "limit" or "failed" after an add that made nothing).
- **Kind 50 `displayControl`**, device → host: `{}` subscribes and brings back its displays;
  `{"action":"add","width":…,"height":…}`, `{"action":"remove","id":…}`, `{"action":"end"}`,
  `{"action":"resize","id":…,"match":"primary"}` or `{"action":"resize","id":…,"width":…,"height":…}`.
  Kind 49's entries carry `matchesPrimary` when true.
- **Kind 51 `displayThumbnail`**, host → a subscribed device every 5 s: an ImageBlob per display,
  id 0 being the Mac's own.

## Where it is

- Wire: `Sources/StreamProtocol/Displays.swift`, `Switcher.swift`, `StreamMessage.swift`.
- Mac: `Sources/SillHost/Displays/` (DisplayPolicy: pure, `Tests/checks/displays`; ExtendedDisplays:
  the displays, memory, put-back and thumbnails), StreamCoordinator (select's `.display` case: an
  SCDisplay filter excluding Sill), StatusText.
- Device: `iOSClient/StreamClient+Displays.swift`, `iOSClient/Desktop/DisplaysTray.swift`,
  QuickControls, DesktopScreen. The last display per Mac is `Sill.lastDisplay.<macID>` in
  UserDefaults; the first request of a connection asks for it. Disconnect sends `end` and closes on
  its completion (1 s at most).
- `Scripts/sillclient.py`: `--displays`, the source `display:ID`, `--raw50=JSON@T`.

## Open questions (default taken)

1. How many: 4 per device.
2. A lost connection: 30 s, so a brief drop leaves the displays and their windows where they are.
3. Disconnect: ends this device's displays now (Gabriel).
4. A new display's size: the room the screen gives the picture, in points.
5. Names: "Display N" by place, the Mac's own counted first (Gabriel: Primary and one more is Display
   2, not 3); no renaming.
7. A display's size: Default or Match Primary, nothing between (Gabriel).
6. Duo dual view: not done (Gabriel).

## Results (2026-10-22)

- `Tests/checks/displays`: every check passes; every mutant caught.
- Against `SillHost --synthetic` (loopback, software encoder) with `sillclient.py`: subscribe; add
  (1180 × 760 and the default); the limit at 4 with "limit"; streaming `display:ID` (the list says
  `showing`, the stream is 1180x760); `end` takes them and the stream goes back to the Desktop;
  reconnecting brings them back and streams `display:ID` at once; removing the streaming display
  goes back to the Desktop; another device sees none; the 30 s grace runs out with its line, and a
  reconnect inside it keeps them.
- Built: the iOS app (installed on the iPad) and Sill.app.
- Resize against the synthetic host: Match Primary and back, the stream staying on the display; the same
  size twice is nothing; the numbering after removing and adding.
- Gabriel, on the iPad: the displays work. Settings per display: `Tests/checks/display-settings` passes
  with every mutant caught; on the iPad, not yet tried.

## Untested on a device (for Gabriel)

- Sill.app making a real display: Add Display on the iPad, "Sill Display 1" in System Settings ›
  Displays, arranged there, windows dragged onto it, the stream showing it, its thumbnail.
- Disconnect and reconnect: the same arrangement, the windows back, opening on the last display.
- A lost connection (Wi-Fi off a moment) inside and past 30 s; Remove; four displays and the fifth
  refused; a single app and Primary as before; the Larger Picture virtual display beside these.
- Settings per display: Retina and 120 fps on Display 1, Standard on Primary; switch between them and
  each comes back; Disconnect and reconnect (it opens on the last display, with its settings); away
  through Tailscale keeps its own; Remove, then Add, starts the new display from what is on.
- Match Primary on a real display: no longer stretched, the windows back after it is made again, its
  arrangement kept; Default back; Disconnect and reconnect keeps Match Primary.
- Two displays, remove both, add one: it is Display 2, here and in the sheet.
- The lit Apps and Displays pills readable; the plus tile.
