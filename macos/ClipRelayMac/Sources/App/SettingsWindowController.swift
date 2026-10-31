// Hosts the SwiftUI Settings window, reachable from the menu bar and by reopening the app.

import AppKit
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        model.refresh()
        if window == nil {
            let w = SettingsWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "ClipRelay Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh()
    }
}

/// The app runs as an accessory with no main menu, so standard window shortcuts don't
/// exist; handle ⌘W and Esc here.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            if let warning = model.bluetoothWarning {
                Section {
                    Button {
                        model.bluetoothWarningAction?()
                    } label: {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Paired Devices") {
                if model.trustedPeers.isEmpty {
                    Text("No paired devices").foregroundStyle(.secondary)
                }
                ForEach(model.trustedPeers, id: \.id) { peer in
                    deviceRow(peer)
                }
                Button("Pair New Device\u{2026}") { model.pairNewDevice() }
            }

            Section("General") {
                Toggle("Show icon in menu bar", isOn: binding(\.showMenuBarIcon))
                if !model.showMenuBarIcon {
                    Text("Open ClipRelay from Finder, Spotlight or Launchpad to return to this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Launch at login", isOn: binding(\.launchAtLogin))
            }

            Section("Sync") {
                Toggle("Image sync (experimental)", isOn: binding(\.imageSync))
                    .disabled(!model.deviceConnected)
                Toggle("Don\u{2019}t sync passwords & secrets", isOn: binding(\.skipSecrets))
                    .help("""
                    When on, clipboard copies that an app marks as secret (concealed) are not sent to \
                    your phone — so passwords stay on this Mac. Works with password managers that flag \
                    copies as concealed, such as Bitwarden, 1Password and KeePassXC. \
                    Note: copies made from browser extensions aren't flagged and will still sync.
                    """)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: binding(\.automaticallyChecksForUpdates))
                Toggle("Beta channel", isOn: binding(\.betaChannel))
                Button(model.availableUpdateVersion.map { "Install Update (\($0))\u{2026}" } ?? "Check for Updates\u{2026}") {
                    model.checkForUpdates()
                }
            }

            Section("Feedback & Support") {
                Button("Report Issue on GitHub\u{2026}") { model.openGitHubIssue() }
                Button("Email Support\u{2026}") { model.openEmail() }
                Button("Copy Diagnostic Logs to Clipboard") { model.copyLogs() }
                Button("Community Discussions\u{2026}") { model.openDiscussions() }
            }

            Section {
                HStack {
                    Text("ClipRelay v\(model.versionString)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Visit Website\u{2026}") { model.openWebsite() }
                    Button("Quit ClipRelay") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 560)
    }

    private func deviceRow(_ peer: PeerSummary) -> some View {
        let connected = model.connectedPeerIDs.contains(peer.id)
        return HStack {
            Circle()
                .fill(connected ? Color(red: 0, green: 1, blue: 0.835) : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.description)
                Text(connected ? "Connected" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let tag = peer.deviceTagHex {
                    Text("Pairing: \(tag)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Forget", role: .destructive) { model.forgetDevice(peer) }
                .buttonStyle(.borderless)
        }
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<SettingsModel, Bool>) -> Binding<Bool> {
        Binding(get: { model[keyPath: keyPath] }, set: { model[keyPath: keyPath] = $0 })
    }
}
