# A paired Mac, reachable wherever it is (this fork, 2026-10-22, branch `dev`)

Gabriel's model: pairing is the only trust. Once a device is paired with a Mac it connects whenever
it can reach it, at home or through a VPN, with nothing more to switch on. A Mac is one thing with
many addresses; the device learns each of them and treats every one as a way to the same Mac. Its
card on the home screen says whether it is online now and how: "Online · Wi‑Fi", "Online ·
Tailscale", "Online · Direct", or "Offline".

This fork is not compatible with later Sill releases (Gabriel, 2026-10-22), so nothing here is
weighed against upstream's compatibility floor, and nobody needs telling.

## What changed

### The Mac

- **Remote Access is on by default** (`HostConfig.standard`, Sill.app's registered default). It stays
  a switch in Settings › Remote Access. Turned off, the Mac gives its devices none of its addresses
  (kind 18 carries none, `remoteAccess` false) and runs no remote door, as before.
- **No internet access at all.** Removed: the switch and its pane section, the router query
  (`RouterAddress.swift`, deleted), the address name, the global IPv6, `HostConfig.internetAccess`,
  `RemoteStatus.internetAccess`/`router`/`addressName`, the trust snapshot's switch, and the CLI's
  `--internet`. The remote door admits loopback, this Mac's networks and VPNs, never an internet
  source (`OriginPolicy.remoteAdmits`, `DoorPolicy.admitsBeforeStart`); `afterGate` still judges the
  origin again (an internet origin there is refused before it starts, so never reaches it). kind
  18's `internet` is always false. The settings `internetAccess` and `remoteAddressName` are
  cleared at launch (`HostSettings.Key.retired`).
- The CLI starts with Remote Access off: its remote door runs only with `--remote`, so it never takes
  7455 from Sill.app.

### The device

- **Every VPN address is kept** (`SavedMacs.remembering`, from `refreshed`): a kind 18 list goes
  first, in the Mac's order, then the VPN addresses this device learned before and the list lacks,
  at most 12. So Tailscale turned on during a session is learned at once (the Mac sends a new kind
  18 the moment its addresses change, as it always did), and a later session at home with
  Tailscale off no longer forgets it. Tailscale keeps a machine's address and MagicDNS name, so a
  remembered one still reaches the Mac. A LAN address is kept only while the Mac lists it: it
  belongs to one network, and at home Bonjour finds the Mac. The dial already tries VPN addresses
  first (`RemoteDialPolicy.order`).
- **Online or offline** (`MacProbe`, `StreamClient.reach`): while the home screen shows, each saved
  Mac that no network or Direct row lists is checked as it appears, every 20 s, as a Mac leaves the
  network's list and as the app comes back. A check tries the Mac's addresses in the dial's order,
  one at a time (4 s each), with TLS 1.3 as a session dial makes it, and stops the handshake in its
  verify block whatever key answered. The first address that shows the Mac's key makes it online,
  named by `RemoteDialPolicy.routeWord` ("Tailscale" for Tailscale's shapes, another VPN's own name,
  "VPN", this network's name for its address dialed directly). None: offline. No check runs while a
  session or a dial does.
- **The card's line** (HomeScreen): a green dot and "Online · Wi‑Fi" / "Wired" / "Direct" while a
  row lists the Mac (orange with "Not paired" or "Update Sill" when that is what a tap does first);
  otherwise the check's "Online · Tailscale", or a grey dot with "Offline" (the picture dimmed) or
  "Checking…". A tap still dials an offline Mac: the check may be stale by seconds.

## Routes on the home screen and in the info panel (Gabriel, 2026-10-22)

- Each card: the picture inside a thin outline that follows its corners (larger: 4 % of its width),
  a little smaller than before. Over its bottom edge are two glass controls: the name and state on
  the left, and Connect │ ⌄ on the right. The idle "Looking for Macs…" line is no longer shown;
  other status lines still are.
- Connect connects the best way, as a tap on the picture does: the nearby row, else the saved
  addresses in the dial's order. The chevron's menu lists every route: the nearby row ("Wi‑Fi ·
  This network", "Direct · Nearby"), then each saved address with its address and the last check's
  answer ("Reachable", "No answer", "Checking…"). The Mac's LAN addresses are left out while the
  nearby row stands for them. Picking an address dials that one alone
  (`dialSaved(_:why:only:)`, as Connect Remotely, so the session doesn't move to the network).
- The check (`MacProbe` with `each`) now tries every address, nearby Macs too, and records each
  answer in `routeReach`. A card's state still comes from the first address that answers. A nearby
  Mac's state stays its row's.
- The info panel's Addresses: the session's own address (a nearby one: the IP the connection
  reached), then each saved address. Each says "Connected", "Reachable", "No answer" or
  "Checking…", from a check of every address made as the panel opens (`checkSessionRoutes`), one
  at a time while the session runs. A check stops in the handshake, so it never becomes a session.
- Routes are grouped by their way (Gabriel): one "Tailscale" (its name, IPv4 and IPv6) and one
  "Wi‑Fi" (IPv4 and IPv6), each showing its IPv4 then its IPv6 (a name only when it has no
  address). Picking one dials every address of it in the dial's order. It is reachable if any
  address answered, and "No answer" only once all of them were checked and none did.
- Untested on the iPad: the card's look; the menu's routes and their answers; picking Tailscale
  at home (it stays on Tailscale); the panel's addresses at home and through Tailscale.

## Security

Unchanged, and what the model rests on:

- Both sides pin each other's key. TLS 1.3 only, no tickets, no resumption. The device pins the
  Mac's key from pairing on every connection, at home and away; the Mac admits only paired keys at
  its remote door. A man in the middle presents a key the pin refuses, so nothing can be
  intercepted or impersonated.
- Addresses are hints, never trust. Each list comes in a kind 18 the Mac's key signed, and every
  dial is pinned anyway, so an address that belongs to someone else by now gets nowhere.
- With internet access gone, the remote door answers only on this Mac's own networks and VPNs. The
  one hole left is upstream's: a router that forwards a port and source-NATs makes an internet peer
  look like `lan`. Pairing still stops it. Don't forward 7455.
- The check is a hint, not a proof. Its verify block sees the Mac's certificate before TLS 1.3's
  CertificateVerify proves the key is held, so "online" means a machine at that address showed this
  Mac's certificate. A tap's dial completes the handshake, pinned, or fails.
- The check never gets the device locked out. The Mac sees a handshake the device ended (-9825) as
  a peer that went away by itself, which counts nothing toward its 5-in-60-s backoff
  (`DoorPolicy.handshakeRefusal`). The device never sends its certificate, so no session starts,
  and nothing goes into the Mac's log.

## Checks

`origin`, `door-policy`, `addresses` and `pairing-address` have lost their internet cases and
gained "never the internet"; their mutants follow (`remote door admits the internet`, `the remote
door takes the internet`, `the origin not judged again`). `remote-rules` checks `remembering`
(Tailscale off at home, back on, ports, the cap) and `routeWord`, with mutants for each part of the
merge.

## Untested on a device, for Gabriel

- The home screen at home: "Online · Wi‑Fi" on the Mac's card.
- Tailscale on the Mac and the iPad while connected at home, then the iPad away (cellular, Tailscale
  on): the card says "Online · Tailscale" within 20 s, and a tap connects.
- The same with Tailscale off on the Mac during the last session at home (the remembered address).
- The Mac asleep or Sill quit: "Offline" within about 20 s.
- The Mac's log while the home screen checks: no lines, and never a backoff (`Sill.log`'s minute
  summaries).
- Remote Access turned off on the Mac: the card goes offline away; Settings › Remote Access has no
  internet section.

## Open questions, with the defaults taken

1. How often to check: every 20 s while the home screen shows, and on its appearing, a Mac leaving
   the network's list and the app returning. No check in the background.
2. A Mac with several working routes away shows the first that answers in the dial's order (VPN
   names, VPN IPv4, VPN IPv6, LAN), not the fastest.
3. An old LAN address is not remembered. A VPN into the home router (WireGuard on the router) then
   works only while the Mac's current LAN address is saved, as before.
