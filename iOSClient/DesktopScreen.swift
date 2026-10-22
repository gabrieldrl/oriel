import SwiftUI
import StreamProtocol

/// The main stream screen, being designed again from the start. For now: the Mac's picture,
/// centred and shaped like a MacBook Pro's display, with all of its input (StreamSurface), the quick
/// controls under it (QuickControls), and the Apps tab at the bottom (AppsTray). The old screen,
/// StreamScreen, stays in the code; `-SillClassicScreen 1` shows it instead (ContentView).
struct DesktopScreen: View {
    @ObservedObject var client: StreamClient
    @State private var overlay = InputOverlayProxy()
    @State private var keyboardShown = false
    @State private var latched: KeyModifiers = []
    /// The picture's size on screen: what the viewport tells the Mac.
    @State private var panelSize: CGSize = .zero
    @State private var pendingViewport: Task<Void, Never>?
    /// The Apps card is up (AppsTray). `-SillAppsOpen 1` starts with it up.
    @State private var appsOpen = UserDefaults.standard.bool(forKey: "SillAppsOpen")
    /// Trackpad input: the whole screen is a relative trackpad that moves a cursor drawn on the
    /// picture, and the iPad's own pointer is the Mac's, instead of a touch landing where it touches.
    /// It follows a pointer device (PointerDeviceMonitor) as one connects or the last goes; the toggle
    /// changes it in between. This device's own, never sent.
    @AppStorage("Sill.trackpadInput") private var trackpadInput = false

    /// The shape until the first frame gives the Mac's own: a 14-inch MacBook Pro's 3024×1964.
    private static let placeholderSize = CGSize(width: 3024, height: 1964)

    private var videoSize: CGSize {
        client.videoSize.width > 0 && client.videoSize.height > 0 ? client.videoSize : Self.placeholderSize
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                display
                    .padding(.bottom, AppsTray.tabHeight)
                // Open, the card takes the screen's taps: one outside it puts it away.
                if appsOpen {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.spring(duration: 0.42, bounce: 0.16)) { appsOpen = false } }
                        .transition(.opacity)
                }
                AppsTray(client: client, open: $appsOpen,
                         previewRadius: panelSize.height * MacDisplayShape.cornerRadiusPerHeight,
                         fullWidth: geo.size.width, bottomInset: geo.safeAreaInsets.bottom)
            }
            // The tab sits on the screen's very edge, over the home indicator's strip.
            .ignoresSafeArea(.container, edges: .bottom)
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
            // This device's cursor shows only while the trackpad moves it; the Mac's shows either way.
            .onChange(of: trackpadInput, initial: true) { _, on in client.setPointerLayout(portrait: on) }
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
                .clipShape(MacDisplayShape())
                .overlay(MacDisplayShape().stroke(Color.white.opacity(0.09), lineWidth: 1))
                // The surface takes the picture's own shape, so the video fills it edge to edge and a
                // touch anywhere on it lands on the Mac.
                .aspectRatio(videoSize, contentMode: .fit)
                .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { panelSize = $0 })
            QuickControls(client: client, trackpadInput: $trackpadInput)
                .frame(width: panelSize.width, alignment: .leading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// A MacBook Pro's display corners (14- and 16-inch, 2021 on), on all four corners. Apple publishes
/// no radius, so this one is an estimate, about 10 pt on the 14-inch's default 1512×982 pt, and
/// scales with the picture's height so it keeps the same proportion at any size.
struct MacDisplayShape: Shape {
    static let cornerRadiusPerHeight: CGFloat = 10.0 / 982.0

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: rect.height * Self.cornerRadiusPerHeight, style: .continuous).path(in: rect)
    }
}
