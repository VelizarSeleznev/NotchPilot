import AppKit
import Foundation
import ServiceManagement

/// Controls Vel's other utilities whose menu bar icons are hidden, over
/// DistributedNotificationCenter: `<id>.command` (object = action string) and
/// `<id>.state` (object = JSON). See each app's docs for the protocol.
@MainActor
final class AppsService: ObservableObject {
    struct Remote {
        let bundleID: String
        let prefix: String
    }

    static let capturePop = Remote(bundleID: "com.velizard.CapturePop", prefix: "com.velizard.CapturePop")
    static let pixelClipboard = Remote(bundleID: "com.velizard.pixel-clipboard", prefix: "com.velizard.pixel-clipboard")
    static let brightIntoshID = "com.velizard.BrightIntosh"

    @Published private(set) var states: [String: [String: Any]] = [:]
    @Published private(set) var running: Set<String> = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let center = DistributedNotificationCenter.default()

    func start() {
        for remote in [Self.capturePop, Self.pixelClipboard] {
            center.addObserver(forName: Notification.Name(remote.prefix + ".state"), object: nil, queue: .main) { [weak self] note in
                guard let json = note.object as? String,
                      let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }
                MainActor.assumeIsolated {
                    self?.states[remote.bundleID] = obj
                }
            }
        }
        refresh()
    }

    func refresh() {
        let ids = [Self.capturePop.bundleID, Self.pixelClipboard.bundleID, Self.brightIntoshID]
        running = Set(ids.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
        send(Self.capturePop, "publishState")
        send(Self.pixelClipboard, "publishState")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func send(_ remote: Remote, _ action: String) {
        center.postNotificationName(Notification.Name(remote.prefix + ".command"), object: action,
                                    userInfo: nil, deliverImmediately: true)
    }

    func state(_ remote: Remote) -> [String: Any] { states[remote.bundleID] ?? [:] }

    func bool(_ remote: Remote, _ key: String) -> Bool { (state(remote)[key] as? Bool) ?? false }

    func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func icon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
    }

    /// Launching an app whose icon is hidden opens its settings (they all handle reopen).
    func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh() }
        }
    }

    func toggleLaunchAtLogin() {
        LoginItem.toggle()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
