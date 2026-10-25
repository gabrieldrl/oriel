# The Mac's desktops in the Displays sheet

Gabriel, 2026-10-25: the Mac's desktops (Mission Control's Spaces) show in the Displays sheet, as
Desktop 1, Desktop 2… in place of Primary, and a tap switches the Mac to that desktop. Each tile keeps
the last picture seen of its desktop. The desktops are those of the display streaming; they follow
the order macOS has them in, and Oriel never reorders, adds or removes one. Extended displays stay
as they are.

## What the person sees

- **The sheet** (DisplaysTray): where Primary was, one tile per desktop of the Mac's own display, in
  Mission Control's order: "Desktop 1"… for a desktop, the app's name for a full-screen app (its line
  "Full screen"). The desktop showing is ringed while the Mac's own display streams. Then the extended
  displays and Add Display, as before. An extended display streaming that has more than one desktop
  shows its desktops in its place, "Display 2 · Desktop 1"….
- **A tap** on a desktop streams its display (when another source streams) and switches the Mac to
  that desktop; the sheet folds. The picture slides as on the Mac.
- **Each tile's picture** is the last one taken of that desktop while it showed (every 5 s with the
  displays' thumbnails, and just after a switch lands), kept on the device per Mac; a desktop not
  seen yet shows the display symbol.
- A Mac that does not list desktops (an older Oriel) shows Primary, as before.

## The rules

1. **Reading:** SkyLight's `SLSCopyManagedDisplaySpaces` (private, `dlsym` as SymbolicHotKeys does),
   per display: its spaces in Mission Control's order and the current one. Type 0 is a desktop, 4 a
   full-screen app (its `pid` names the app); every other type is left out. Desktops are numbered
   among desktops only, as Mission Control does ("Desktop 3" is the third desktop, full-screen apps
   between them not counted) (`DesktopPolicy.named`).
2. **Which display:** a display's set is matched by its UUID (`CGDisplayCreateUUIDFromDisplayID`).
   With Displays have separate Spaces off, macOS keeps one set, "Main", for every display: it is the
   Mac's own (`DesktopPolicy.assign`). A device sees the Mac's own display's set and its own extended
   displays' (another device's never).
3. **Switching:** macOS has no call that switches reliably (setting the current space privately
   leaves the Dock behind). The host posts Move left a space or Move right a space (⌃← and ⌃→, read
   from the Mac's Keyboard Shortcuts as the gestures do: GestureChords), one step at a time, each
   after the last one landed (the current space changed, or 1.5 s), up to 16 steps
   (`DesktopPolicy.steps`). A shortcut that is off: nothing moves, and the log says which to turn on.
   A new switch replaces one still stepping. Before stepping on a display the pointer is not on, the
   pointer goes to that display's middle (the shortcut acts on the pointer's display).
4. **Pictures:** a thumbnail is a desktop's only when its display's current space is the same just
   before and just after the capture (`DesktopPolicy.tagged`): one taken across a switch is nobody's.
5. **Changes:** while a device subscribes, the host reads the sets every second and at
   NSWorkspace's active-space notification, and sends the list when it changed.
6. **Synthetic host:** three desktops and a full-screen "Safari" on its own display, one desktop on
   each extended display; a switch moves at once, and each desktop's picture is a flat colour. Nothing
   on this Mac is read or posted.
7. **Available** when SkyLight has the call (`MacSpaces.available`), or synthetic. A device only
   offers desktops with a Mac that makes displays (the sheet is the Displays sheet).

## The wire (additive)

- `WindowList.desktops: Int?`: 1 is `DesktopControl.generation`.
- **Kind 53 `desktops`**, host → a subscribed device: `DesktopList {displays: [{display, current,
  desktops: [{id, name, app}]}]}`; `display` 0 is the Mac's own, else an `ExtendedDisplay.id`; `id`
  the space's (UInt64); `app` set for a full-screen app.
- **Kind 54 `desktopControl`**, device → host: `{}` subscribes; `{"display":0,"id":5}` switches.
- **Kind 55 `desktopThumbnail`**, host → a subscribed device: the space id (8 bytes, big-endian),
  then a JPEG.
- Only to a host whose window list says `desktops` 1 does a device send kind 54.

## Where it is

- Wire: `Sources/StreamProtocol/Desktops.swift`, `Switcher.swift` (`desktops`), `StreamMessage.swift`.
- Mac: `Sources/SillHost/Desktops/` (DesktopPolicy: pure, `Tests/checks/desktops`; MacSpaces: the
  SkyLight read; HostDesktops: subscribers, the list, switching, thumbnails), StreamCoordinator.
- Device: `iOSClient/StreamClient+Desktops.swift`, `iOSClient/Desktop/DesktopPictures.swift`,
  DisplaysTray.

## Open questions (default taken)

1. Primary's tile: replaced by the desktops (Gabriel).
2. Which desktops: the Mac's own display's always, an extended display's while it streams (Gabriel:
   the current display's).
3. Order: macOS's, never changed from Oriel; no adding or removing (Gabriel).
4. Full-screen apps: listed, by their app's name, as Mission Control shows them.
5. Switch to Desktop N (⌃1…): not used. It counts desktops only and is off as macOS ships; the
   arrows reach full-screen apps too.
6. Pictures: kept on the device in Caches per Mac and desktop; Forget on the home screen removes them.

## Results (2026-10-25)

- `Tests/checks/desktops`: 58 checks, and 30 of 30 mutants caught (one more, "the after picture's",
  was equivalent and dropped). The displays and curtain mutants that renumbered a kind to 53 or 54
  now use 60 to 62, which no kind takes.
- On this Mac, a scratch reader of `SLSCopyManagedDisplaySpaces` listed its display with 8 desktops
  and a full-screen app (type 4, with its `pid`), the full-screen app showing; Move left and right a
  space (79 and 81) are on, Switch to Desktop N (118…) off.
- Against `SillHost --synthetic` (loopback, software encoder), the iPad simulator: the sheet shows
  Desktop 1 to 3 and Safari (Full screen) in Primary's place, Desktop 1 ringed with its picture; a tap
  on Desktop 3 switches it ("switched the Mac's display to Desktop 3"), the ring moves and Desktop 3
  gets its picture while Desktop 1 keeps its own. Add Display streams Display 2, ringed alone; a tap on
  Desktop 2 from there streams the Mac's display again and switches it. The iPhone simulator's sheet
  shows the same desktops, and not the iPad's Display 2.
- Built: the iOS app and Sill.app.
- Found on the iPhone (2026-10-25, not the desktops' doing): with the Mac's display asleep a pick
  streamed nothing, without a line in the log (the picture black), and a switch did not move. A pick
  now wakes the display first and, while anything streams, it does not idle to sleep
  (`Sources/SillHost/DisplayWake.swift`).

## Untested on a device (for Gabriel)

- Oriel.app with a real Mac: the sheet lists this Mac's desktops in Mission Control's order with the
  full-screen apps by name; a tap slides to the desktop, one step at a time, far ones too (8 desktops);
  the ring follows a switch made on the Mac itself; a desktop added or removed in Mission Control
  appears or goes within a second or so.
- The pictures: each desktop's after it has shown once, kept after reconnecting and after the app
  restarts; none taken mid-slide.
- An extended display with two desktops (add one in Mission Control with the pointer on it): its
  desktops in its place while it streams, and a switch moving that display, not the Mac's own (the
  pointer goes there first).
- Move left a space turned off in Keyboard Shortcuts: nothing moves, and the log says so.
- Displays have separate Spaces off: the Mac's own display's set alone, no desktops for an extended
  display.
