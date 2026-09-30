import AppKit
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
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
            withAnimation(.spring(response: 0.36, dampingFraction: 0.92)) { state.expanded = false }
        }
    }
}

extension AppModel {
    /// Cheap refreshes that only matter while the island is visible.
    func islandOpened() {
        toggles.refresh()
        sessions.pruneClosedTabs()
        mixer.refreshProcesses()
    }
}
