import Foundation
import StreamProtocol

// The Mac's desktops, this device's side (kinds 53 to 55; Desktops.swift, docs/desktops-plan.md): in
// the Displays sheet (DisplaysTray) the Mac's own display's desktops take Primary's place, and an
// extended display streaming shows its own; a tap switches the Mac to one. Each desktop's last
// picture is kept on this device (DesktopPictures).
//
// - The subscription: a kind 54 `{}` at the first window list that says `desktops`, again on a move's
//   new connection.
// - A switch streams the desktop's display first when another source streams, then asks the Mac to
//   switch it, which it does with its own Move left and right a space, one desktop at a time.
//
// Everything here is main thread.
extension StreamClient {
    /// The Mac lists its desktops (its window list's `desktops`).
    var hostHasDesktops: Bool { (hostDesktops ?? 0) >= DesktopControl.generation }

    /// Each window list's `desktops`: the first that says so subscribes.
    func hostDesktopsChanged(_ value: Int?) {
        if hostDesktops != value { hostDesktops = value }
        guard hostHasDesktops, !desktopsSubscribed else { return }
        desktopsSubscribed = true
        send(.desktopControl, payload: Wire.encode(DesktopControl()))
    }

    /// A move handed the session to its new connection: the Mac keeps subscriptions per connection.
    func desktopsMoved() {
        desktopsSubscribed = false
        hostDesktopsChanged(hostDesktops)
    }

    /// The session ended: only the pictures stay.
    func resetDesktops() {
        hostDesktops = nil
        desktopsSubscribed = false
        desktopList = DesktopList(displays: [])
    }

    /// A kind 53 from the Mac.
    func receiveDesktops(_ list: DesktopList) {
        if desktopList != list { desktopList = list }
    }

    /// A kind 55: a desktop's picture, kept for this Mac.
    func receiveDesktopPicture(_ id: UInt64, jpeg: Data) {
        DesktopPictures.shared.keep(jpeg, desktop: id, of: session?.macID)
    }

    /// Display `display`'s desktops (0: the Mac's own), when the Mac listed them.
    func desktops(on display: UInt32) -> DesktopSet? {
        hostHasDesktops ? desktopList.set(display) : nil
    }

    /// The source that streams display `display`.
    static func source(of display: UInt32) -> StreamSource {
        display == DesktopControl.macDisplay ? .desktop : .display(display)
    }

    /// A tap on desktop `id` of display `display`: that display streams, and the Mac switches it.
    func switchDesktop(_ id: UInt64, on display: UInt32) {
        guard hostHasDesktops else { return }
        let source = Self.source(of: display)
        if active != source { select(source) } else { noteAction() }
        guard desktops(on: display)?.current != id else { return }
        send(.desktopControl, payload: Wire.encode(DesktopControl(display: display, id: id)))
    }
}
