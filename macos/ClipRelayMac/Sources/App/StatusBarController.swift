// Manages the macOS menu bar icon, status dot, and dropdown menu for peer management.

import AppKit
import Foundation
import QuartzCore
import Sparkle

final class StatusBarController {
    var onPairNewDeviceRequested: (() -> Void)?
    var onForgetDeviceRequested: ((String) -> Void)?
    var onOpenSettingsRequested: (() -> Void)?

    private var availableUpdateVersion: String?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let updaterController: SPUStandardUpdaterController

    private var connectedPeers: [PeerSummary] = []
    private var trustedPeers: [PeerSummary] = []
    private var bluetoothWarning: String?
    private var bluetoothWarningAction: (() -> Void)?

    private static let brandAqua = NSColor(red: 0, green: 1, blue: 0.835, alpha: 1) // #00FFD5

    private lazy var connectedDot: NSImage = makeStatusDot(color: Self.brandAqua)
    private lazy var disconnectedDot: NSImage = makeStatusDot(color: .tertiaryLabelColor)

    private var statusBarImage: NSImage?

    init(updaterController: SPUStandardUpdaterController) {
        self.updaterController = updaterController
        statusBarImage = loadStatusBarIcon()
        statusItem.isVisible = SettingsModel.isMenuBarIconVisible
        updateStatusBarIcon()
        renderMenu()
    }

    var isIconVisible: Bool {
        statusItem.isVisible
    }

    func setIconVisible(_ visible: Bool) {
        statusItem.isVisible = visible
        if visible {
            updateStatusBarIcon()
        }
    }

    /// Template image: macOS tints it to match the menu bar (white on a dark bar) in every
    /// state, so the icon never changes color. Loaded by name so the @2x variant is used.
    private func loadStatusBarIcon() -> NSImage? {
        guard let image = Bundle.main.image(forResource: "StatusBarIcon") else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem.button else { return }
        guard let image = statusBarImage else {
            button.title = "GP"
            return
        }
        button.image = image
        if bluetoothWarning != nil {
            // A Bluetooth problem means the app is inactive: overlay a yellow warning badge.
            showWarningBadge(on: button)
        } else {
            hideWarningBadge(on: button)
        }
    }

    private static let warningBadgeLayerName = "clipRelayWarningBadge"

    /// Overlays a small yellow "!" badge on the top-right of the status item. Drawn as a
    /// layer (not composited into the image) so the glyph keeps its template appearance and
    /// the badge never intercepts the menu click.
    private func showWarningBadge(on button: NSStatusBarButton) {
        button.wantsLayer = true
        guard let host = button.layer else { return }

        let badge: CALayer
        if let existing = host.sublayers?.first(where: { $0.name == Self.warningBadgeLayerName }) {
            badge = existing
        } else {
            badge = CALayer()
            badge.name = Self.warningBadgeLayerName
            host.addSublayer(badge)
        }

        let pointSize: CGFloat = 9
        let scale = button.window?.backingScaleFactor ?? 2
        badge.contents = makeWarningBadgeImage(pixelDiameter: pointSize * scale)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        badge.contentsGravity = .resizeAspect
        badge.contentsScale = scale

        // Sit over the top-right corner of the centered 18pt glyph. The button's backing
        // layer is flipped (top-left origin), so the glyph's top edge is the smaller y.
        let bounds = button.bounds
        let glyph: CGFloat = 18
        let glyphMaxX = (bounds.width + glyph) / 2
        let glyphMinY = (bounds.height - glyph) / 2
        badge.frame = CGRect(x: glyphMaxX - pointSize + 1, y: glyphMinY - 1,
                             width: pointSize, height: pointSize)
    }

    private func hideWarningBadge(on button: NSStatusBarButton) {
        button.layer?.sublayers?
            .first { $0.name == Self.warningBadgeLayerName }?
            .removeFromSuperlayer()
    }

    /// A yellow disc with a dark "!" — drawn proportionally so it stays crisp at any scale.
    private func makeWarningBadgeImage(pixelDiameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: pixelDiameter, height: pixelDiameter), flipped: false) { rect in
            let w = rect.width
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: rect).fill()

            NSColor.black.setFill()
            let stemW = w * 0.16
            let stem = NSRect(x: rect.midX - stemW / 2, y: rect.midY - w * 0.03, width: stemW, height: w * 0.32)
            NSBezierPath(roundedRect: stem, xRadius: stemW / 2, yRadius: stemW / 2).fill()
            let dotD = w * 0.18
            let dot = NSRect(x: rect.midX - dotD / 2, y: rect.midY - w * 0.30, width: dotD, height: dotD)
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
    }

    func setConnectedPeers(_ peers: [PeerSummary]) {
        connectedPeers = peers
        updateStatusBarIcon()
        renderMenu()
    }

    func setTrustedPeers(_ peers: [PeerSummary]) {
        trustedPeers = peers
        renderMenu()
    }

    func setBluetoothWarning(_ warning: String?, action: (() -> Void)? = nil) {
        bluetoothWarning = warning
        bluetoothWarningAction = action
        updateStatusBarIcon()
        renderMenu()
    }


    /// Briefly pulses the status bar icon to indicate a clipboard sync.
    func flashSyncIndicator() {
        guard statusItem.isVisible, let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1.0, 1.3, 1.0]
        pulse.keyTimes = [0, 0.4, 1.0]
        pulse.duration = 0.35
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "syncPulse")
    }

    // MARK: - Menu rendering

    func setAvailableUpdateVersion(_ version: String?) {
        availableUpdateVersion = version
        renderMenu()
    }

    /// Shows the status menu at the mouse location — escape hatch for when the
    /// menu bar icon is inaccessible (e.g. hidden under the notch).
    func popUpMenuAtMouse() {
        renderMenu()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func renderMenu() {
        menu.removeAllItems()

        if let bluetoothWarning {
            let hasAction = bluetoothWarningAction != nil
            let warningItem = NSMenuItem(
                title: bluetoothWarning,
                action: hasAction ? #selector(handleBluetoothWarningSelected) : nil,
                keyEquivalent: ""
            )
            let warningSymbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "warning")
            // Two palette colors. The symbol's first layer is the exclamation, second is the
            // triangle, so order them black then yellow for a yellow triangle + black mark.
            warningItem.image = warningSymbol?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.black, .systemYellow])
            )
            warningItem.target = self
            warningItem.isEnabled = hasAction
            menu.addItem(warningItem)
            menu.addItem(NSMenuItem.separator())
        }

        renderTrustedDevicesSection()
        menu.addItem(NSMenuItem.separator())

        let pairItem = NSMenuItem(
            title: "Pair New Device\u{2026}",
            action: #selector(handlePairNewDevice),
            keyEquivalent: "n"
        )
        pairItem.target = self
        menu.addItem(pairItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        if SettingsModel.inAppUpdatesEnabled {
            let updateTitle: String
            if let version = availableUpdateVersion {
                updateTitle = "Update Available (\(version))"
            } else {
                updateTitle = "Check for Updates\u{2026}"
            }
            let checkForUpdatesItem = NSMenuItem(title: updateTitle, action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            checkForUpdatesItem.target = updaterController
            menu.addItem(checkForUpdatesItem)
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit ClipRelay",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    private func renderTrustedDevicesSection() {
        let header = NSMenuItem(title: "Paired Devices", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if trustedPeers.isEmpty {
            let empty = NSMenuItem(title: "  No paired devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let connectedIDs = Set(connectedPeers.map(\.id))

        for peer in trustedPeers {
            let isConnected = connectedIDs.contains(peer.id)

            let title: String
            if let tag = peer.deviceTagHex {
                title = "\(peer.description)  [Pairing: \(tag)]"
            } else {
                title = peer.description
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = isConnected ? connectedDot : disconnectedDot
            item.isEnabled = true

            let submenu = NSMenu()
            let forgetItem = NSMenuItem(
                title: "Forget Device",
                action: #selector(handleForgetDevice(_:)),
                keyEquivalent: ""
            )
            forgetItem.target = self
            forgetItem.representedObject = peer.secret
            submenu.addItem(forgetItem)

            item.submenu = submenu
            menu.addItem(item)
        }
    }

    // MARK: - Status dot

    private func makeStatusDot(color: NSColor) -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Actions

    @objc
    private func handlePairNewDevice() {
        onPairNewDeviceRequested?()
    }

    @objc
    private func handleBluetoothWarningSelected() {
        bluetoothWarningAction?()
    }

    @objc
    private func handleOpenSettings() {
        onOpenSettingsRequested?()
    }

    @objc
    private func handleForgetDevice(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String else { return }
        onForgetDeviceRequested?(token)
    }
}
