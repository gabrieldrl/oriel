import SwiftUI
import StreamProtocol

/// The main stream screen, being designed again from the start. For now: the Mac's picture,
/// centred and shaped like a MacBook Pro's display, with all of its input (StreamSurface), the quick
/// controls under it (QuickControls), the Apps pill among them, whose sheet rises over the picture from its bottom
/// edge (AppsTray). The old screen,
/// StreamScreen, stays in the code; `-SillClassicScreen 1` shows it instead (ContentView).
struct DesktopScreen: View {
    @ObservedObject var client: StreamClient
    @State private var overlay = InputOverlayProxy()
    @State private var keyboardShown = false
    @State private var latched: KeyModifiers = []
    /// The picture's size on screen: what the viewport tells the Mac.
    @State private var panelSize: CGSize = .zero
    @State private var pendingViewport: Task<Void, Never>?
    /// The Apps sheet is up over the picture (AppsTray). `-SillAppsOpen 1` starts with it up.
    @State private var appsOpen = UserDefaults.standard.bool(forKey: "SillAppsOpen")
    /// The key row's sheet is up (KeyRowSheet). It and the Apps sheet rise from the same edge, so
    /// one opening puts the other away.
    @State private var keyRowOpen = UserDefaults.standard.bool(forKey: "SillKeyRowOpen")
    /// The Displays sheet is up (DisplaysTray), from the same edge. `-SillDisplaysOpen 1` starts with it up.
    @State private var displaysOpen = UserDefaults.standard.bool(forKey: "SillDisplaysOpen")
    /// The screen's size: the most room the picture has (`room`), a new display's size.
    @State private var screenSize: CGSize = .zero
    /// The info panel is up at the picture's top-right corner (InfoPanel). `-SillInfoOpen 1` starts with it up.
    @State private var infoOpen = UserDefaults.standard.bool(forKey: "SillInfoOpen")
    /// Trackpad input: the whole screen is a relative trackpad that moves a cursor drawn on the
    /// picture, and the iPad's own pointer is the Mac's, instead of a touch landing where it touches.
    /// It follows a pointer device (PointerDeviceMonitor) as one connects or the last goes; the toggle
    /// changes it in between. This device's own, never sent.
    @AppStorage("Sill.trackpadInput") private var trackpadInput = false
    /// The quick control that is open, if any: a touch anywhere else folds it (QuickPillFocus).
    @StateObject private var pillFocus = QuickPillFocus()
    /// The picture's ripple (DisplayRipple), run up to 1 on Disconnect before the connect screen
    /// returns; the controls fade with it.
    @State private var ripple: CGFloat = 0
    /// The session's first look: the screen fades in.
    @State private var shown = false
    /// Close was tapped (or held): the ripple runs out, then the session ends. Nothing takes a touch meanwhile.
    @State private var leaving = false

    /// The shape until the first frame gives the Mac's own: a 14-inch MacBook Pro's 3024×1964.
    private static let placeholderSize = CGSize(width: 3024, height: 1964)
    /// Between the info button and the picture's top edge.
    private static let infoGap: CGFloat = 8

    private var videoSize: CGSize {
        client.videoSize.width > 0 && client.videoSize.height > 0 ? client.videoSize : Self.placeholderSize
    }

    var body: some View {
        GeometryReader { _ in
            display
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                if screenSize != size { screenSize = size }
            }
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(!leaving)
            .environment(\.quickPillFocus, pillFocus)
            .coordinateSpace(.named(QuickPillFocus.space))
            // While a quick control is open, a touch anywhere else folds it and goes no further.
            .overlay { pillFocus.catcher }
        }
        .background(Color.black.ignoresSafeArea())
            // A hardware keyboard types on the Mac whenever one is attached: nothing here takes it.
            .onReceive(HardwareKeyboardMonitor.shared.$attached) { overlay.update(attached: $0) }
            // A pointer device connecting or the last one going sets the mode; one already attached
            // as the screen opens makes it Trackpad, and none leaves the last choice.
            .onReceive(PointerDeviceMonitor.shared.$attached.removeDuplicates().dropFirst()) { trackpadInput = $0 }
            .onAppear {
                if PointerDeviceMonitor.shared.attached { trackpadInput = true }
                overlay.update(takers: [])
                // With nothing streaming the client asks for the Desktop by itself
                // (DiscoveryPolicy.autoDesktop); a window picked from Apps streams in its place.
                sendViewport()
            }
            .onChange(of: client.connected) { _, up in if up { sendViewport() } }
            // The session's first look: a plain fade in.
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { shown = true } }
            // This device's cursor shows only while the trackpad moves it; the Mac's shows either way.
            .onChange(of: trackpadInput, initial: true) { _, on in client.setPointerLayout(portrait: on) }
            .onChange(of: appsOpen) { _, up in if up { keyRowOpen = false; displaysOpen = false } }
            .onChange(of: keyRowOpen) { _, up in if up { appsOpen = false; displaysOpen = false } }
            .onChange(of: displaysOpen) { _, up in if up { appsOpen = false; keyRowOpen = false } }
            // Rotation animates, so let the size settle.
            .onChange(of: panelSize) { _, _ in sendViewport(after: 0.25) }
    }

    /// The picture, with the quick controls right under it at its leading edge; the two centred
    /// together.
    private var display: some View {
        VStack(spacing: 16) {
            // Touch: a finger on the picture is the Mac's pointer where it touches, and the iPad's
            // own pointer does nothing there. Trackpad: the picture is a trackpad for fingers, and
            // the iPad's pointer (a Magic Keyboard's trackpad, a mouse) goes through it to be the Mac's.
            StreamSurface(client: client, overlay: overlay, keyboardShown: $keyboardShown, latched: $latched,
                          takesFingers: !trackpadInput, takesPointer: trackpadInput)
                .overlay { if trackpadInput { trackpad } }
                .background(Palette.panel)
                .displayRipple(ripple)
                .clipShape(MacDisplayShape())
                .overlay(MacDisplayShape().stroke(Color.white.opacity(0.09), lineWidth: 1))
                // The Apps sheet: the black under the picture rising over it (a touch anywhere else
                // puts it away, QuickPillFocus).
                .overlay(alignment: .bottom) {
                    KeyRowSheet(client: client, open: $keyRowOpen, latched: $latched, picture: panelSize)
                        .opacity(1 - ripple)
                }
                // The Mac's name just above the picture, centred, in line with the info button.
                .overlay(alignment: .top) {
                    Text(client.macName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .frame(maxWidth: max(panelSize.width - 2 * (InfoButton.size + 16), 0))
                        .alignmentGuide(.top) { $0[.bottom] + Self.infoGap + (InfoButton.size - $0.height) / 2 }
                        .opacity(1 - ripple)
                        .accessibilityAddTraits(.isHeader)
                }
                // The info button just above the picture's top-right corner, its panel on the corner.
                .overlay(alignment: .topTrailing) {
                    InfoButton(open: infoOpen) { withAnimation(.spring(duration: 0.35, bounce: 0.12)) { infoOpen.toggle() } }
                        .alignmentGuide(.top) { $0[.bottom] + Self.infoGap }
                        .opacity(1 - ripple)
                }
                .overlay(alignment: .topTrailing) {
                    if infoOpen {
                        InfoPanel(client: client, open: $infoOpen)
                            .padding(12)
                            .transition(.scale(scale: 0.85, anchor: .topTrailing).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.35, bounce: 0.12), value: infoOpen)
                .overlay(alignment: .bottom) {
                    AppsTray(client: client, open: $appsOpen,
                             previewRadius: panelSize.height * MacDisplayShape.cornerRadiusPerHeight,
                             picture: panelSize)
                        .opacity(1 - ripple)
                }
                .overlay(alignment: .bottom) {
                    DisplaysTray(client: client, open: $displaysOpen,
                                 previewRadius: panelSize.height * MacDisplayShape.cornerRadiusPerHeight,
                                 picture: panelSize, room: room)
                        .opacity(1 - ripple)
                }
                // The surface takes the picture's own shape, so the video fills it edge to edge and a
                // touch anywhere on it lands on the Mac.
                .aspectRatio(videoSize, contentMode: .fit)
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    if panelSize != size { panelSize = size }
                }
            QuickControls(client: client, trackpadInput: $trackpadInput, onLeave: leave,
                          appsOpen: appsOpen, onApps: { appsOpen.toggle() },
                          displaysOpen: displaysOpen, onDisplays: { displaysOpen.toggle() },
                          keyboardShown: keyboardShown, onKeyboard: { overlay.toggleKeyboard() },
                          keyRowOpen: $keyRowOpen, displayRoom: room)
                .frame(width: panelSize.width, alignment: .leading)
                .opacity(1 - ripple)
        }
        .padding(24)
        // Room above the picture for the info button.
        .padding(.top, InfoButton.size + Self.infoGap - 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The most room the picture has on this screen, in points: the screen less the margins, the room
    /// above for the info button and the controls under it. A new display is made this size, so it
    /// fills the screen as the picture.
    private var room: CGSize {
        let top = 24 + InfoButton.size + Self.infoGap - 16
        return CGSize(width: max(screenSize.width - 48, 0),
                      height: max(screenSize.height - top - 24 - 16 - QuickControlStyle.height, 0))
    }

    /// Close, or Disconnect: the ripple runs out from the picture's centre, then the session ends and
    /// the home screen comes back. Disconnect also ends the Mac's connection (MacLinks), so nothing
    /// runs for this device there; Close leaves it connected.
    private func leave(disconnect: Bool) {
        guard !leaving else { return }
        leaving = true
        let macID = client.session?.macID
        if disconnect, let macID { MacLinks.shared.disconnect(macID) }
        pillFocus.closeOpen()
        appsOpen = false
        keyRowOpen = false
        displaysOpen = false
        infoOpen = false
        withAnimation(.easeOut(duration: 0.6)) { ripple = 1 } completion: { client.disconnect() }
    }

    /// The picture as a trackpad, as the old upright layout's pad is (TrackpadSurface: move, tap,
    /// two-finger tap, hold to drag, two-finger scroll, three-finger gestures), drawing nothing of its
    /// own: a stroke across the picture moves the pointer across the Mac's frame, and down it, down.
    private var trackpad: some View {
        TrackpadView(send: { client.sendInput($0) },
                     setPointer: { client.setOwnPointer($0, from: .trackpad) },
                     feed: { let f = client.pointerFeedState; return (f.anchor, f.reseeds) },
                     onFingers: { client.trackpadFingers($0) },
                     latched: latched,
                     onModifiersConsumed: { latched = [] },
                     verticalSpan: nil,
                     sendGesture: { client.sendGesture($0, fingers: $1) },
                     fingersOnly: true)
    }

    /// The picture's size and this device's frame rate. The Mac streams the Desktop at its own size
    /// whatever this says, but takes the rate from it (60 fps without one).
    private func sendViewport(after delay: Double = 0) {
        pendingViewport?.cancel()
        pendingViewport = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
            }
            guard client.connected, panelSize.width > 0, panelSize.height > 0 else { return }
            client.sendViewport(Viewport(width: Double(panelSize.width), height: Double(panelSize.height), scale: nil,
                                         fps: StreamClient.wantedFPS(remote: client.awayCapsFrameRate)))
        }
    }
}

/// A MacBook Pro's display corners (14- and 16-inch, 2021 on), on all four corners, a little rounder
/// than the display's own. Apple publishes no radius, so this one is a choice, 14 pt on the 14-inch's
/// default 1512×982 pt, and scales with the picture's height so it keeps the same proportion at any size.
struct MacDisplayShape: Shape {
    static let cornerRadiusPerHeight: CGFloat = 14.0 / 982.0

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: rect.height * Self.cornerRadiusPerHeight, style: .continuous).path(in: rect)
    }
}
