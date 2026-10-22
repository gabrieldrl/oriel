import SwiftUI

/// Which quick control is open (the Quality picker, the sound's slider), if any, and where it is on
/// screen. At most one is open: one opening closes the one before. While one is, DesktopScreen lays a
/// catcher over the whole screen but that control (`catcher`): a touch anywhere else closes it, and
/// goes no further (no click on the Mac, no other control).
///
/// A control opens with `opened(_:close:)`, saying how to close it, reports its frame in the screen's
/// space (`QuickPillFocus.space`) while open, and says `closed(_:)` when it has closed, whoever closed
/// it. Main thread.
@MainActor
final class QuickPillFocus: ObservableObject {
    /// The named coordinate space of the screen the catcher covers.
    nonisolated static let space = "sill.quickControls"

    @Published private(set) var openID: String?
    /// The open control's frame in `space`: the hole in the catcher.
    @Published private(set) var frame: CGRect = .zero
    private var closer: (() -> Void)?

    func opened(_ id: String, close: @escaping () -> Void) {
        if openID != id, let before = closer {
            closer = nil
            before()
        }
        openID = id
        closer = close
        #if DEBUG
        print("pill: \(id) opened")
        #endif
    }

    func closed(_ id: String) {
        guard openID == id else { return }
        #if DEBUG
        print("pill: \(id) closed")
        #endif
        openID = nil
        closer = nil
        frame = .zero
    }

    /// The open control's frame, as it lays out (it moves while it morphs).
    func moved(_ id: String, to frame: CGRect) {
        guard openID == id, abs(frame.minX - self.frame.minX) + abs(frame.width - self.frame.width)
                + abs(frame.minY - self.frame.minY) > 0.5 else { return }
        self.frame = frame
    }

    /// A touch outside the open control.
    func closeOpen() {
        #if DEBUG
        if let openID { print("pill: a touch outside \(openID) (\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height)))") }
        #endif
        closer?()
    }

    /// Over the screen while a control is open: takes every touch but those on the control.
    @ViewBuilder var catcher: some View {
        if openID != nil {
            Color.clear
                .contentShape(Punched(hole: frame), eoFill: true)
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in self.closeOpen() })
                .accessibilityHidden(true)
        }
    }

    /// The whole rect with the open control cut out of it.
    private struct Punched: Shape {
        let hole: CGRect
        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            // A pill's ends, or the Apps sheet's top corners (32).
            let radius = min(hole.height / 2, 32)
            if !hole.isEmpty { path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius)) }
            return path
        }
    }
}

private struct QuickPillFocusKey: EnvironmentKey {
    static let defaultValue: QuickPillFocus? = nil
}

extension EnvironmentValues {
    /// The screen's QuickPillFocus; nil where nothing closes an open control from outside.
    var quickPillFocus: QuickPillFocus? {
        get { self[QuickPillFocusKey.self] }
        set { self[QuickPillFocusKey.self] = newValue }
    }
}

extension View {
    /// While `id` is open, its frame to `focus` (the catcher's hole).
    func reportsPillFrame(_ id: String, to focus: QuickPillFocus?, while open: Bool) -> some View {
        onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(QuickPillFocus.space)) }) { frame in
            if open { focus?.moved(id, to: frame) }
        }
    }
}
