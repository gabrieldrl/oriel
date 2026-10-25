import SwiftUI
import StreamProtocol

/// The Displays pill beside Apps (QuickControls): its icon and "Displays". A tap opens the Displays
/// sheet (DisplaysTray); while it is up the pill is lit, as Apps is. Only for a Mac that makes
/// extended displays (`StreamClient.hostMakesDisplays`).
struct DisplaysPill: View {
    let open: Bool
    let onTap: () -> Void

    var body: some View {
        QuickPillFace(icon: DisplaysTray.icon, text: "Displays")
            .quickPillFrame(open ? .black : .white)
            .background(Capsule().fill(open ? Color.white : QuickControlStyle.fill))
            .contentShape(Capsule())
            .onTapGesture { onTap() }
            .animation(.easeOut(duration: 0.2), value: open)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Displays")
            .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { onTap() }
    }
}

/// The Displays sheet, a RisingSheet over the picture as Apps' is: the Mac's own display (Primary),
/// then this device's extended displays (StreamClient+Displays, docs/displays-plan.md), each a picture
/// of it with its name under it, and Add Display while there is room for one more. A tap streams that
/// display; Add Display (a dashed plus) makes one at the room this screen shows it in and streams it; a display's menu
/// removes it for good, its windows going to the Mac's own display. Each is a display to macOS:
/// arranged in System Settings › Displays, windows dragged onto it on the Mac.
///
/// With a Mac that lists its desktops (StreamClient+Desktops, docs/desktops-plan.md), Primary is the
/// Mac's own display's desktops, one tile each in Mission Control's order ("Desktop 1"…, a full-screen
/// app by its name), and an extended display streaming with more than one desktop shows its own in its
/// place; a tap streams that display and switches the Mac to that desktop. Each tile shows the last
/// picture of its desktop (DesktopPictures).
struct DisplaysTray: View {
    @ObservedObject var client: StreamClient
    @ObservedObject private var desktops = MacDesktops.shared
    @ObservedObject private var desktopPictures = DesktopPictures.shared
    @Binding var open: Bool
    /// The previews' corners: the Desktop's own on screen.
    let previewRadius: CGFloat
    /// The Mac's picture on screen, which the sheet rises over.
    let picture: CGSize
    /// The most room this screen gives the picture: a new display's size.
    let room: CGSize

    @State private var gridHeight: CGFloat = 0

    static let icon = "display.2"
    private static let headerHeight: CGFloat = 72
    private static let padding: CGFloat = 24
    private static let spacing: CGFloat = 20
    private static let minCell: CGFloat = 200

    private var width: CGFloat { RisingSheetStyle.width(over: picture.width) }

    private var openHeight: CGFloat {
        let room = max(picture.height - Self.padding, 0)
        return min(Self.headerHeight + max(gridHeight, 80) + Self.padding, room).rounded()
    }

    var body: some View {
        RisingSheet(open: $open, width: width, height: openHeight, focusID: "Displays") { content }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                grid
                    .padding(.horizontal, Self.padding)
                    .padding(.bottom, Self.padding)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                        let content = h - Self.padding
                        if abs(gridHeight - content) > 0.5 { gridHeight = content }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon).font(QuickControlStyle.iconFont)
            Text("Displays").font(.system(size: 20, weight: .semibold))
            if client.displaysProblem == "failed" {
                Text("The Mac couldn’t add a display.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            Button { open = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(QuickControlStyle.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Displays")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Self.padding)
        .frame(height: Self.headerHeight)
        .accessibilityElement(children: .contain)
    }

    private var grid: some View {
        let inner = width - 2 * Self.padding
        let count = max(2, Int((inner + Self.spacing) / (Self.minCell + Self.spacing)))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: count),
                         alignment: .leading, spacing: Self.spacing) {
            if let set = client.desktops(on: DesktopControl.macDisplay), !set.desktops.isEmpty {
                ForEach(set.desktops) { desktop in
                    desktopPreview(desktop, of: set, name: desktop.name,
                                   detail: client.macName.isEmpty ? "This Mac’s display" : client.macName)
                }
            } else {
                DisplayPreview(image: client.displayPictures[0] ?? client.session?.macID.flatMap { desktops.pictures[$0] },
                               name: "Primary", detail: client.macName.isEmpty ? "This Mac’s display" : client.macName,
                               radius: previewRadius, isActive: client.active == .desktop) { pick(.desktop) }
            }
            ForEach(client.extendedDisplays) { d in
                if client.active == .display(d.id), let set = client.desktops(on: d.id), set.desktops.count > 1 {
                    ForEach(set.desktops) { desktop in
                        desktopPreview(desktop, of: set, name: "\(d.name) · \(desktop.name)", detail: "\(d.width) × \(d.height)")
                            .modifier(RemoveDisplay(client: client, display: d))
                    }
                } else {
                    DisplayPreview(image: client.displayPictures[d.id], name: d.name, detail: "\(d.width) × \(d.height)",
                                   radius: previewRadius, isActive: client.active == .display(d.id)) { pick(.display(d.id)) }
                        .modifier(RemoveDisplay(client: client, display: d))
                }
            }
            if client.canAddDisplay {
                AddDisplayTile(radius: previewRadius) {
                    client.addDisplay(size: room)
                    open = false
                }
            }
        }
    }

    private func pick(_ source: StreamSource) {
        if client.active != source { client.select(source) }
        open = false
    }

    /// One desktop of display `set.display`: its last picture (the display's own while it shows, until
    /// one of the desktop comes), ringed while it streams and shows.
    private func desktopPreview(_ desktop: MacDesktop, of set: DesktopSet, name: String, detail: String) -> some View {
        let showing = set.current == desktop.id
        let macID = client.session?.macID
        let image = desktopPictures.picture(desktop.id, of: macID)
            ?? (showing ? client.displayPictures[set.display] : nil)
            ?? (showing && set.display == DesktopControl.macDisplay ? macID.flatMap { desktops.pictures[$0] } : nil)
        return DisplayPreview(image: image, name: name, detail: desktop.app == nil ? detail : "Full screen",
                              radius: previewRadius,
                              isActive: showing && client.active == StreamClient.source(of: set.display)) {
            client.switchDesktop(desktop.id, on: set.display)
            open = false
        }
    }
}

/// An extended display's menu and accessibility action: Remove, for good.
private struct RemoveDisplay: ViewModifier {
    let client: StreamClient
    let display: ExtendedDisplay

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(role: .destructive) { client.removeDisplay(display.id) } label: {
                    Label("Remove \(display.name)", systemImage: "minus.circle")
                }
            }
            .accessibilityAction(named: "Remove \(display.name)") { client.removeDisplay(display.id) }
    }
}

/// One display in the sheet: its picture at 16:10, then its name and a line under it.
private struct DisplayPreview: View {
    let image: UIImage?
    let name: String
    let detail: String
    let radius: CGFloat
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                Color.clear
                    .aspectRatio(1.6, contentMode: .fit)
                    .overlay { picture }
                    .clipShape(frame)
                    .overlay(frame.strokeBorder(isActive ? Palette.accent : Color.white.opacity(0.12),
                                                lineWidth: isActive ? 2 : 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .foregroundStyle(.white)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name + ", \(detail)" + (isActive ? ", showing now" : ""))
    }

    @ViewBuilder private var picture: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Palette.panel
                Image(systemName: "display")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }
}

/// Add Display: a dashed outline the shape of a preview, a plus in it, and no words.
private struct AddDisplayTile: View {
    let radius: CGFloat
    let onTap: () -> Void

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: onTap) {
            Color.clear
                .aspectRatio(1.6, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .overlay(frame.strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                .contentShape(frame)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Display")
        .accessibilityHint("Adds a display to the Mac, the size of this screen, and shows it here.")
    }
}
