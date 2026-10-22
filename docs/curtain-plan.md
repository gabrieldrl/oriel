# The Mac's screen off

Gabriel, 2026-10-22: a pill beside Clipboard and Disconnect that turns the connected Mac's screen
dark and stops its own keyboard and trackpad, while the device goes on working the Mac. It is off by
default and kept per Mac on the device.

## What the person sees

- **The pill**, between Clipboard and Disconnect, only for a Mac whose window list says `curtain` 1.
  It shows `eye` while off and `eye.slash` on a white pill while on. It turns orange when the Mac
  refused (no Accessibility for Sill), and its accessibility label is "Mac's Screen Off".
- **On the Mac**, while it is on:
  - every one of its own displays is black (not Sill's virtual displays);
  - the built-in display's brightness is 0;
  - its own keyboard, trackpad, mouse and system keys (brightness, volume, media) do nothing.
  - The device's picture is the Mac as before. What the device types, clicks and scrolls still
    reaches the Mac.
- **Off** puts it all back, the brightness as it was.

## The rules

1. The curtain is up while any connection wants it, and down the moment none does: that device's
   `off`, its connection gone (Disconnect, a drop, a move), or Sill quitting. Nobody is left with a
   dark, locked Mac behind a device that went away.
2. On the device it is kept per Mac (`Sill.curtain.<macID>`). It is sent at the first window list
   that says `curtain`, and again on a move's new connection. A tap is applied at once; the Mac's
   answer then corrects it.
3. Input: an event tap at the HID level (`cghidEventTap`, head insert, a default tap) on a thread of
   its own. It drops the event types in `CurtainPolicy.blocked` unless the event's source user data
   is `CurtainPolicy.marker`, which InputInjector stamps on every event it posts. A tap that macOS
   turns off (timeout or user input) is turned on again.
4. Picture: borderless black windows at `CGShieldingWindowLevel`, which clicks pass through, made
   again when the screens change. Sill's windows are excluded from every capture, so the stream
   doesn't show them. That exclusion is fixed when a stream starts, though, so once the windows are
   up a stream of the Mac's own display starts again (`onCovered`, StreamCoordinator's
   `curtainCovered`). Gabriel, on the iPad: without that restart the iPad showed black until he
   switched display and back.
5. Brightness: DisplayServices (private, loaded with dlopen) on built-in displays. It is set to 0
   and set again every 3 s against automatic brightness. The first level read is restored when the
   curtain comes down. An external display only gets the black window.
6. The tap needs Accessibility (`AXIsProcessTrusted`). Without it nothing goes up, and the device
   gets `on: false, problem: "accessibility"`.
7. A synthetic host keeps only the state: nothing on this Mac changes.

## The wire (additive)

- `WindowList.curtain: Int?`: 1 means this host can do it. Sill.app and a synthetic host advertise
  it; the CLI on a real Mac doesn't (no AppKit loop for the windows).
- **Kind 52 `curtain`**, both ways, `CurtainControl {on, problem?}`.
  - From the device, it is what that device wants.
  - From the host, it is the state for that device: `on` only while it wants it and the curtain is
    up, and `problem` only when it wants it and the curtain could not go up.
  - The host answers the sender, and every device that wants it hears each change.

## Where it is

- Wire: `Sources/StreamProtocol/Curtain.swift`, `Switcher.swift`, `StreamMessage.swift`.
- Mac: `Sources/SillHost/Curtain/` (CurtainPolicy, pure, `Tests/checks/curtain`; MacCurtain: the
  wanting set, the tap, the windows and the brightness), StreamCoordinator (the dispatch, `clientLeft`
  and shutdown), InputInjector (the marker).
- Device: `iOSClient/StreamClient+Curtain.swift`, `CurtainControl` in QuickControls.
- `Scripts/sillclient.py`: `--raw52=JSON@T`, kind 52 printed, the list's `curtain=`.

## Open questions (default taken)

1. The icon: `eye` / `eye.slash` (Gabriel suggested an eyelid; SF Symbols has no eyelid, and
   eye.slash reads as "the Mac can't be seen").
2. Two devices: up while either wants it; each device's pill shows its own want.
3. The Mac's own Esc or a key chord to lift it from the Mac: none (Gabriel asked for its input
   blocked). Quitting Sill, or the device leaving, lifts it.
4. External displays' brightness (DDC): not done; they are black instead.

## Results (2026-10-22)

- `Tests/checks/curtain`: every check passes; every mutant caught. `pointer-control` knows kind 52.
- Against `SillHost --synthetic` with `sillclient.py`: the list says `curtain=1`; on and off each get
  one answer with the host's line; a device that leaves with it on takes it down.
- Built: the iOS app (installed on the iPad) and Sill.app.

## Untested on a device (for Gabriel)

- The pill on the iPad:
  - the Mac goes black at brightness 0;
  - its keyboard, trackpad and brightness keys do nothing;
  - the iPad still types, clicks and scrolls on the Mac and sees it.
- Off: the brightness comes back as it was. Disconnect, and a dropped connection, lift it.
- Kept per Mac: reconnecting turns it on again; another Mac starts off.
- Without Accessibility: the pill turns orange and nothing changes on the Mac.
- With an extended display streaming: the virtual display is not covered. An external monitor goes
  black.
- Automatic brightness doesn't win. The lid, sleep and the lock screen while it is on.
