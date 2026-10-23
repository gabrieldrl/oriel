import AppKit
import SwiftUI
import SillHostCore
import StreamProtocol

/// One line of the status menu, as data. `MenuBuilder` makes the list, the status item turns it
/// into NSMenuItems, and the previews hook prints it to menu.txt, so the three cannot disagree.
struct MenuEntry: Equatable {
    enum Kind: Equatable { case card, item, separator }
    enum Action: Equatable {
        case none
        case allowScreenRecording, allowAccessibility, openPrivacy
        /// These two are absolute, like the radio items: each sets what the item offered when the
        /// menu was built (on when it showed unchecked). A device can change the setting while the
        /// menu is open, which does not rebuild it, and a toggle would then do the opposite of what
        /// the item shows.
        case setVirtualDisplay(Bool)
        case setDirectWireless(Bool)
        case setMaxFPS(Int), setBitrate(Int), setCaptureScale(CGFloat)
        case toggleLaunchAtLogin
        case showLog, showSettings, quit
        /// Settings on one tab (Remote Access…); the plain `showSettings` stays for ⌘,. (Swift
        /// allows no second case named `showSettings`.)
        case showSettingsTab(SettingsTab)
        /// Pair iPhone or iPad…: a pairing window, or the open one brought forward.
        case showPairing
        /// "‹device› Wants to Pair": the window that shows its code brought forward, else one
        /// opened on the Mac, asked by that device.
        case showPairingRequest(name: String, showing: Bool)
        /// Sill 0.4 Is Available…: the release's page on GitHub, in the browser (UpdateChecker).
        case openUpdate(URL)
    }

    var kind: Kind
    var title = ""
    var subtitle: String?
    var checked = false
    var enabled = true
    /// An orange warning in front: something needs the user.
    var attention = false
    /// ⌘ plus this key.
    var key = ""
    var action: Action = .none
    var children: [MenuEntry] = []

    static let separator = MenuEntry(kind: .separator)
}

/// The status menu, top to bottom: whether a device is connected, then Settings… and Quit.
/// Everything else lives in the Settings window.
enum MenuBuilder {
    static func entries(presentation p: StatusPresentation) -> [MenuEntry] {
        [
            MenuEntry(kind: .card, title: StatusCard.header(p.connectedDevices)),
            .separator,
        ] + (p.updateThisMac ? [
            // A device runs a newer Oriel than this Mac (VersionMatch): the latest release's page.
            MenuEntry(kind: .item, title: "Update Oriel on This Mac…", attention: true, action: .openUpdate(UpdatePolicy.latestPage)),
            .separator,
        ] : []) + [
            MenuEntry(kind: .item, title: "Settings…", key: ",", action: .showSettings),
            .separator,
            MenuEntry(kind: .item, title: "Quit Oriel", key: "q", action: .quit),
        ]
    }

    /// The live menu for `model` as it would open now (the status item's rebuild, and
    /// -SillPrintMenuAfter).
    @MainActor
    static func entries(for model: AppModel) -> [MenuEntry] {
        entries(presentation: model.presentation)
    }

    /// The menu as text, for the previews: "✓" checked, "⚠" attention, "(off)" disabled.
    static func dump(_ entries: [MenuEntry], card: StatusPresentation? = nil, indent: String = "") -> String {
        var out = ""
        for e in entries {
            switch e.kind {
            case .separator:
                out += indent + "────────\n"
            case .card:
                out += indent + "[card] \(e.title)\n"
                for (i, name) in (card?.connectedDevices ?? []).enumerated() {
                    out += indent + "       · \(name)\n"
                    if let notes = card?.versionNotes, i < notes.count, let note = notes[i] { out += indent + "         ⚠ \(note)\n" }
                }
            case .item:
                let mark = e.attention ? "⚠ " : (e.checked ? "✓ " : "  ")
                var line = indent + mark + e.title
                if !e.key.isEmpty { line += "  ⌘" + e.key.uppercased() }
                if !e.enabled { line += "  (off)" }
                if let s = e.subtitle { line += "  — \(s)" }
                out += line + (e.children.isEmpty ? "\n" : " ▸\n")
                if !e.children.isEmpty { out += dump(e.children, indent: indent + "    ") }
            }
        }
        return out
    }
}

/// The menu bar item and its menu. The menu is rebuilt each time it opens (permissions and the
/// login item re-read first), and the status card inside it follows the host live while it is
/// open. Every control only sets `model.settings.config`, the one path to the coordinator.
///
/// Its actions are AppKit target/action, the one safe place to start what may run a modal loop
/// (NSApp.terminate): see AppDelegate.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let model: AppModel
    private let card: NSHostingView<LiveStatusCard>
    private var glyph: StatusGlyph.State?
    private var menuOpen = false

    private static let attentionImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Needs attention")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }()

    init(model: AppModel) {
        self.model = model
        card = NSHostingView(rootView: LiveStatusCard(model: model))
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.autosaveName = "SillStatusItem"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        show(model.presentation)
    }

    /// The glyph, tooltip and accessibility label for a new presentation.
    func show(_ p: StatusPresentation) {
        guard let button = item.button else { return }
        if glyph != p.glyph {
            glyph = p.glyph
            button.image = StatusGlyph.image(p.glyph)
        }
        button.toolTip = p.tooltip
        button.setAccessibilityLabel(p.accessibilityLabel)
        // A device joining while the menu is open makes the card taller.
        if menuOpen { card.frame.size = card.fittingSize }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.permissions.refresh()
        model.loginItem.refresh()
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func rebuild() {
        menu.removeAllItems()
        for entry in MenuBuilder.entries(for: model) {
            menu.addItem(makeItem(entry))
        }
    }

    private func makeItem(_ e: MenuEntry) -> NSMenuItem {
        switch e.kind {
        case .separator:
            return .separator()
        case .card:
            let cardItem = NSMenuItem()
            card.frame = NSRect(origin: .zero, size: card.fittingSize)
            cardItem.view = card
            return cardItem
        case .item:
            let menuItem = NSMenuItem(title: e.title, action: e.action == .none ? nil : #selector(menuAction(_:)), keyEquivalent: e.key)
            menuItem.target = self
            menuItem.representedObject = e.action
            menuItem.state = e.checked ? NSControl.StateValue.on : .off
            menuItem.isEnabled = e.enabled
            if let subtitle = e.subtitle {
                menuItem.subtitle = subtitle
            }
            if e.attention { menuItem.image = Self.attentionImage }
            if !e.children.isEmpty {
                let submenu = NSMenu(title: e.title)
                submenu.autoenablesItems = false
                for child in e.children { submenu.addItem(makeItem(child)) }
                menuItem.submenu = submenu
            }
            return menuItem
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuEntry.Action else { return }
        switch action {
        case .none: break
        case .allowScreenRecording: model.permissions.requestScreenRecording()
        case .allowAccessibility: model.permissions.requestAccessibility()
        case .openPrivacy: model.permissions.openPrivacyPane()
        case .setVirtualDisplay(let on): model.settings.config.virtualDisplay = on
        case .setDirectWireless(let on): model.settings.config.directWireless = on
        case .setMaxFPS(let fps): model.settings.config.maxFPS = fps
        case .setBitrate(let bitrate): model.settings.config.bitrate = bitrate
        case .setCaptureScale(let scale): model.settings.config.captureScale = scale
        case .toggleLaunchAtLogin: model.loginItem.set(!model.loginItem.isOn)
        case .showLog: model.showLog?()
        case .showSettings: model.showSettings?(nil)
        case .showSettingsTab(let tab): model.showSettings?(tab)
        case .showPairing: model.pairDevice()
        case .showPairingRequest(let name, let showing): model.showPairingRequest(name: name, showing: showing)
        case .openUpdate(let url): NSWorkspace.shared.open(url)   // the browser; no modal loop
        case .quit: NSApp.terminate(nil)
        }
    }
}
