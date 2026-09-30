import AppKit
import ApplicationServices

/// One-button controls borrowed from other menu bar apps:
/// BrightIntosh (XDR brightness) through its CLI, Macs Fan Control through its menu.
@MainActor
final class QuickToggles: ObservableObject {
    @Published private(set) var xdrOn = false
    @Published private(set) var xdrAvailable = false
    @Published private(set) var fansMax = false
    @Published private(set) var fansAvailable = false
    @Published var message: String?

    static let brightIntoshIDs = ["com.velizard.BrightIntosh", "de.brightintosh.app", "de.niklasr22.BrightIntosh"]
    static let fanControlID = "com.crystalidea.macsfancontrol"

    private var brightIntoshURL: URL? {
        Self.brightIntoshIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    func refresh() {
        refreshXDR()
        refreshFans()
    }

    // MARK: - XDR brightness (BrightIntosh)

    private func refreshXDR() {
        guard let app = brightIntoshURL else { xdrAvailable = false; return }
        xdrAvailable = true
        runCLI(app, "status") { [weak self] out in
            self?.xdrOn = out?.contains("Enabled") ?? false
        }
    }

    func toggleXDR() {
        guard let app = brightIntoshURL else { return }
        let target = !xdrOn
        xdrOn = target
        ensureRunning(app) { [weak self] in
            self?.runCLI(app, target ? "enable" : "disable") { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refreshXDR() }
            }
        }
    }

    private func runCLI(_ app: URL, _ command: String, completion: @escaping @MainActor (String?) -> Void) {
        let exe = app.appendingPathComponent("Contents/MacOS").appendingPathComponent(
            (Bundle(url: app)?.executableURL?.lastPathComponent) ?? "BrightIntosh")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = exe
            p.arguments = ["cli", command]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var out: String?
            if (try? p.run()) != nil {
                p.waitUntilExit()
                out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    private func ensureRunning(_ app: URL, then: @escaping @MainActor () -> Void) {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL == app }
        if running { then(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { then() }
        }
    }

    // MARK: - Fans (Macs Fan Control)

    private func refreshFans() {
        fansAvailable = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.fanControlID) != nil
        CFPreferencesAppSynchronize(Self.fanControlID as CFString)
        let preset = CFPreferencesCopyAppValue("ActivePreset" as CFString, Self.fanControlID as CFString) as? String
        fansMax = preset == "Predefined:1"
    }

    func toggleFans() {
        guard fansAvailable else { return }
        guard AXIsProcessTrusted() else {
            message = "Allow NotchPilot in Privacy → Accessibility to drive Macs Fan Control"
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            return
        }
        let target = !fansMax
        fansMax = target
        let item = target ? "Full blast" : "Automatic"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.fanControlID).first else {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.fanControlID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.fansMax = !target; self?.toggleFans() }
                }
            }
            return
        }
        let pid = app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.pressStatusMenuItem(pid: pid, title: item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if !ok { self?.message = "Couldn't reach Macs Fan Control's menu" }
                self?.refreshFans()
            }
        }
    }

    /// Opens an app's menu bar extra and presses the item with the given title.
    nonisolated private static func pressStatusMenuItem(pid: pid_t, title: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        guard let bar = element(app, "AXExtrasMenuBar"),
              let barItem = children(bar).first else { return false }
        AXUIElementPerformAction(barItem, kAXPressAction as CFString)
        var target: AXUIElement?
        for _ in 0..<20 {
            if let menu = children(barItem).first {
                target = children(menu).first { string($0, kAXTitleAttribute) == title }
                if target != nil { break }
            }
            usleep(50_000)
        }
        guard let target else {
            AXUIElementPerformAction(barItem, kAXCancelAction as CFString)
            return false
        }
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    nonisolated private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    nonisolated private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
