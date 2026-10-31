// Observable state and actions behind the Settings window: preferences, paired devices, and support links.

import AppKit
import Foundation
import Sparkle
import UserNotifications

final class SettingsModel: ObservableObject {
    static let showMenuBarIconKey = "showMenuBarIcon"

    @Published var trustedPeers: [PeerSummary] = []
    @Published var connectedPeerIDs: Set<UUID> = []
    @Published var bluetoothWarning: String?
    var bluetoothWarningAction: (() -> Void)?
    @Published var availableUpdateVersion: String?

    var onPairNewDeviceRequested: (() -> Void)?
    var onForgetDeviceRequested: ((String) -> Void)?
    var onShowMenuBarIconChanged: ((Bool) -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var isLaunchAtLoginEnabled: (() -> Bool)?
    var onToggleImageSync: (() -> Void)?
    /// Fired when "Don't Sync Passwords & Secrets" flips to ON.
    var onSkipSecretsEnabled: (() -> Void)?
    var isImageSyncEnabled: (() -> Bool)?
    var isDeviceConnected: (() -> Bool)?
    var bleStateProvider: (() -> String)?

    let updaterController: SPUStandardUpdaterController

    init(updaterController: SPUStandardUpdaterController) {
        self.updaterController = updaterController
    }

    /// Re-reads values that live outside this model (SMAppService, Sparkle, ConnectionController).
    func refresh() {
        objectWillChange.send()
    }

    // MARK: - Preferences

    var showMenuBarIcon: Bool {
        get { Self.isMenuBarIconVisible }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.showMenuBarIconKey)
            onShowMenuBarIconChanged?(newValue)
            refresh()
        }
    }

    /// Builds without a Sparkle feed are updated through Homebrew instead.
    static var inAppUpdatesEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    static var isMenuBarIconVisible: Bool {
        UserDefaults.standard.object(forKey: showMenuBarIconKey) as? Bool ?? true
    }

    var launchAtLogin: Bool {
        get { isLaunchAtLoginEnabled?() ?? false }
        set {
            guard newValue != launchAtLogin else { return }
            onToggleLaunchAtLogin?()
            refresh()
        }
    }

    var deviceConnected: Bool { isDeviceConnected?() ?? false }

    var imageSync: Bool {
        get { isImageSyncEnabled?() ?? false }
        set {
            guard newValue != imageSync else { return }
            onToggleImageSync?()
            refresh()
        }
    }

    var skipSecrets: Bool {
        get { ClipboardMonitor.skipSecretsEnabled }
        set {
            ClipboardMonitor.skipSecretsEnabled = newValue
            if newValue {
                onSkipSecretsEnabled?()
            }
            refresh()
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            updaterController.updater.automaticallyChecksForUpdates = newValue
            refresh()
        }
    }

    var betaChannel: Bool {
        get { Self.isBetaChannelEnabled }
        set {
            var channels = UserDefaults.standard.stringArray(forKey: "SUDefaultChannels") ?? []
            channels.removeAll { $0 == "beta" }
            if newValue {
                channels.append("beta")
            }
            if channels.isEmpty {
                UserDefaults.standard.removeObject(forKey: "SUDefaultChannels")
            } else {
                UserDefaults.standard.set(channels, forKey: "SUDefaultChannels")
            }
            refresh()
        }
    }

    private static var isBetaChannelEnabled: Bool {
        let channels = UserDefaults.standard.stringArray(forKey: "SUDefaultChannels") ?? []
        return channels.contains("beta")
    }

    // MARK: - Devices & updates

    func pairNewDevice() {
        onPairNewDeviceRequested?()
    }

    func forgetDevice(_ peer: PeerSummary) {
        guard let secret = peer.secret else { return }
        onForgetDeviceRequested?(secret)
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    // MARK: - Support

    var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    func openWebsite() {
        if let url = URL(string: "https://cliprelay.org") {
            NSWorkspace.shared.open(url)
        }
    }

    func openGitHubIssue() {
        let context = deviceContext()
        let body = "\n\n---\n" + context.map { "- **\($0.0):** \($0.1)" }.joined(separator: "\n")
        var components = URLComponents(string: "https://github.com/geekflyer/cliprelay/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "from-app"),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    func openEmail() {
        let context = deviceContext()
        let body = "\n\n---\n" + context.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        var components = URLComponents(string: "mailto:info@cliprelay.org")!
        components.queryItems = [
            URLQueryItem(name: "subject", value: "ClipRelay Feedback"),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    func openDiscussions() {
        if let url = URL(string: "https://github.com/geekflyer/cliprelay/discussions") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyLogs() {
        let context = deviceContext()
        DispatchQueue.global(qos: .userInitiated).async {
            let text = LogShareExporter.exportLogs(deviceContext: context)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                // Mark the copy concealed so the skip-secrets filter keeps the log dump
                // local; the 100 KB sync cap only catches dumps that outgrow it.
                NSPasteboard.general.setString("", forType: ClipboardMonitor.concealedType)
                Self.notifyLogsCopied(byteCount: text.utf8.count)
            }
        }
    }

    private static func notifyLogsCopied(byteCount: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let kb = max(1, byteCount / 1024)
        let content = UNMutableNotificationContent()
        content.title = "Logs copied to clipboard"
        content.body = "\(kb) KB ready to paste into a bug report."
        let request = UNNotificationRequest(identifier: "logs-copied", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func deviceContext() -> [(String, String)] {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        var model = "Unknown Mac"
        var size: Int = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0 {
            var machine = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &machine, &size, nil, 0) == 0 {
                model = String(cString: machine)
            }
        }
        let bleState = bleStateProvider?() ?? "unknown"
        #if DEBUG
        let buildType = "debug"
        #else
        let buildType = "release"
        #endif
        let flags = [
            "imageSync=\(imageSync)",
            "skipSecrets=\(skipSecrets)",
            "autoUpdate=\(automaticallyChecksForUpdates)",
            "betaChannel=\(betaChannel)",
            "menuBarIcon=\(showMenuBarIcon)",
        ].joined(separator: ", ")
        return [
            ("App Version", "\(versionString) (\(build)) [\(buildType)]"),
            ("OS", osString),
            ("Device", model),
            ("BLE State", bleState),
            ("Paired Devices", "\(trustedPeers.count) (\(connectedPeerIDs.count) connected)"),
            ("Flags", flags),
        ]
    }
}
