import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Observable island geometry and state. The window never moves or resizes;
/// only the SwiftUI shape inside it animates, which keeps the motion smooth.
@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    /// Notch size of the built-in display (falls back to a typical 14" MacBook Pro notch).
    @Published var notchSize = CGSize(width: 185, height: 32)
    /// Frame of the visible island in window coordinates (top-left origin), for hit testing.
    var islandRect: CGRect = .zero
    /// True while a slider or scroll gesture is in progress; keeps the island open.
    @Published var interacting = false
    /// A fullscreen window covers the notch screen: stay invisible unless hovered.
    @Published var fullscreen = false
    /// Which page the expanded island shows.
    @Published var page: Page = .main
    /// Short message shown in the collapsed island (e.g. the output picked by the shortcut).
    @Published var toast: (symbol: String, text: String)?
    enum Page { case main, apps }
}

final class NotchPanel: NSPanel {
    // Never take keyboard focus: a key non-activating panel swallows keystrokes meant for the front app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController {
    static let windowSize = CGSize(width: 760, height: 560)

    private let panel: NotchPanel
    private let state = IslandState()
    private var monitors: [Any] = []
    private var pendingCollapse: DispatchWorkItem?
    private var pendingExpand: DispatchWorkItem?
    private var outputHotKey: HotKey?
    private var hideToast: DispatchWorkItem?

    /// ⌃⌥⌘O switches between headphones and the built-in speakers.
    static let outputShortcut = (keyCode: kVK_ANSI_O, modifiers: controlKey | optionKey | cmdKey)

    init() {
        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar + 2
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true

        let model = AppModel.shared
        let root = IslandRootView()
            .environmentObject(state)
            .environmentObject(model.nowPlaying)
            .environmentObject(model.sessions)
            .environmentObject(model.outputs)
            .environmentObject(model.mixer)
            .environmentObject(model.toggles)
            .environmentObject(model.apps)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: Self.windowSize)
        panel.contentView = host

        placeOnBuiltInScreen()
        panel.orderFrontRegardless()
        model.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeOnBuiltInScreen() }
        }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFullscreenCheck() }
            }
        }
        // Entering fullscreen animates; also catch windows that go fullscreen without switching apps.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFullscreen() }
        }

        outputHotKey = HotKey(keyCode: Self.outputShortcut.keyCode, modifiers: Self.outputShortcut.modifiers, id: 1) { [weak self] in
            MainActor.assumeIsolated { self?.cycleOutput() }
        }
        if outputHotKey == nil { Log.write("output shortcut registration failed") }

        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(m)
        }
    }

    private func cycleOutput() {
        let outputs = AppModel.shared.outputs
        outputs.reload()
        let before = outputs.current?.name ?? "?"
        outputs.cycle()
        Log.write("output shortcut: \(before) -> \(outputs.current?.name ?? "?")")
        guard let device = outputs.current else { return }
        hideToast?.cancel()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { state.toast = (device.symbol, device.name) }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(IslandRootView.shrink) { self?.state.toast = nil }
            }
        }
        hideToast = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func scheduleFullscreenCheck() {
        updateFullscreen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.updateFullscreen() }
    }

    /// True when the notch screen shows a native fullscreen Space, or the frontmost app
    /// covers the whole screen (borderless games). Native fullscreen windows on notched
    /// Macs sit below the notch, so their bounds never equal the screen.
    private func updateFullscreen() {
        guard let screen = targetScreen else { return }
        var isFull = SpaceInfo.isFullscreenSpace(on: screen)
        if !isFull, let front = NSWorkspace.shared.frontmostApplication,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            // CG window coordinates are top-left based on the primary display.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let f = screen.frame
            let screenCG = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
            isFull = list.contains { info in
                guard (info[kCGWindowOwnerPID as String] as? pid_t) == front.processIdentifier,
                      let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
                let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                return r.contains(screenCG)
            }
        }
        if isFull != state.fullscreen {
            Log.write("fullscreen \(isFull)")
            withAnimation(.easeOut(duration: 0.2)) { state.fullscreen = isFull }
        }
    }

    /// The screen with a notch (built-in display), else the main screen.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func placeOnBuiltInScreen() {
        guard let screen = targetScreen else { return }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notchSize = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            state.notchSize = CGSize(width: 185, height: NSStatusBar.system.thickness)
        }
        let origin = NSPoint(x: frame.midX - Self.windowSize.width / 2, y: frame.maxY - Self.windowSize.height)
        panel.setFrame(NSRect(origin: origin, size: Self.windowSize), display: true)
    }

    /// Mouse position in window coordinates with a top-left origin.
    private func mouseInWindow() -> CGPoint {
        let p = NSEvent.mouseLocation
        let f = panel.frame
        return CGPoint(x: p.x - f.minX, y: f.maxY - p.y)
    }

    private func mouseMoved() {
        let p = mouseInWindow()
        let notch = state.notchSize
        // Hover zone around the physical notch: slightly wider, reaching the very top edge.
        let hotZone = CGRect(
            x: (Self.windowSize.width - notch.width) / 2 - 10, y: 0,
            width: notch.width + 20, height: notch.height + 4
        )
        let overIsland = state.islandRect.insetBy(dx: -4, dy: -4).contains(p)
        let overHot = hotZone.contains(p)

        // Only swallow clicks where the island actually is.
        panel.ignoresMouseEvents = !(overIsland || overHot)

        if overHot || (state.expanded && overIsland) {
            pendingCollapse?.cancel()
            pendingCollapse = nil
            if !state.expanded, pendingExpand == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.setExpanded(true) }
                }
                pendingExpand = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
            }
        } else {
            pendingExpand?.cancel()
            pendingExpand = nil
            if state.expanded, pendingCollapse == nil, !state.interacting {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.setExpanded(false) }
                }
                pendingCollapse = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
            }
        }
    }

    private func setExpanded(_ expanded: Bool) {
        pendingExpand = nil
        pendingCollapse = nil
        guard state.expanded != expanded else { return }
        if expanded {
            AppModel.shared.islandOpened()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { state.expanded = true }
        } else {
            withAnimation(IslandRootView.shrink) { state.expanded = false }
            state.page = .main
        }
    }
}

extension AppModel {
    /// Cheap refreshes that only matter while the island is visible.
    func islandOpened() {
        toggles.refresh()
        sessions.pruneClosedTabs()
        mixer.refreshProcesses()
        apps.refresh()
    }
}

/// Space type of a display via SkyLight (private, resolved at runtime; 4 = fullscreen).
enum SpaceInfo {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let mainConnection: MainConnection? = dlsym(skyLight, "SLSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self) }
    private static let copySpaces: CopyManagedDisplaySpaces? = dlsym(skyLight, "SLSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopyManagedDisplaySpaces.self) }

    static func isFullscreenSpace(on screen: NSScreen) -> Bool {
        guard let mainConnection, let copySpaces,
              let displays = copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return false }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let uuid = number.flatMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
            .map { CFUUIDCreateString(nil, $0) as String }
        // With "Displays have separate Spaces" off there is a single entry ("Main").
        let display = displays.count == 1 ? displays.first
            : displays.first { ($0["Display Identifier"] as? String) == uuid }
        let current = display?["Current Space"] as? [String: Any]
        return (current?["type"] as? Int) == 4
    }
}
