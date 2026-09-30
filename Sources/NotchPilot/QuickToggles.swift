import AppKit

/// One-button controls borrowed from other menu bar apps:
/// BrightIntosh (XDR brightness) through its CLI, fans through NotchPilot's own SMC helper.
@MainActor
final class QuickToggles: ObservableObject {
    @Published private(set) var xdrOn = false
    @Published private(set) var xdrAvailable = false
    @Published private(set) var fansMax = false
    @Published private(set) var fansAvailable = false
    @Published var message: String?

    static let brightIntoshIDs = ["com.velizard.BrightIntosh", "de.brightintosh.app", "de.niklasr22.BrightIntosh"]

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

    // MARK: - Fans (own root helper, see FanHelper/ and script/install_fan_helper.sh)

    static let fanHelperPath = "/Library/PrivilegedHelperTools/com.velizard.notchpilot.fand"
    static let fanModeFile = "/Users/Shared/NotchPilot/fan-mode"
    private var wakeObserver: Any?

    private func refreshFans() {
        fansAvailable = FileManager.default.fileExists(atPath: Self.fanHelperPath)
        let mode = (try? String(contentsOfFile: Self.fanModeFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        fansMax = mode == "max"
        if wakeObserver == nil {
            // The SMC can hand fans back to the system over sleep; re-apply "max" on wake.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.fansMax == true { self?.writeFanMode("max") }
                }
            }
        }
    }

    func toggleFans() {
        guard fansAvailable else {
            message = "Fan helper not installed: run script/install_fan_helper.sh from the NotchPilot repo"
            return
        }
        fansMax.toggle()
        writeFanMode(fansMax ? "max" : "auto")
    }

    private func writeFanMode(_ mode: String) {
        do {
            try (mode + "\n").write(toFile: Self.fanModeFile, atomically: false, encoding: .utf8)
        } catch {
            message = "Can't write \(Self.fanModeFile): \(error.localizedDescription)"
        }
    }
}
