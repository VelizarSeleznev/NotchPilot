import AppKit
import SwiftUI

/// Settings and quick actions of utilities that no longer live in the menu bar.
struct AppsPage: View {
    @EnvironmentObject var apps: AppsService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if apps.isInstalled(AppsService.capturePop.bundleID) {
                capturePop
            }
            if apps.isInstalled(AppsService.pixelClipboard.bundleID) {
                pixelClipboard
            }
            if apps.isInstalled(AppsService.brightIntoshID) {
                AppCard(bundleID: AppsService.brightIntoshID, title: "BrightIntosh",
                        subtitle: apps.running.contains(AppsService.brightIntoshID) ? "XDR toggle is on the main page" : "Not running") {
                    ActionChip(symbol: "gearshape", title: "Settings") { apps.openApp(AppsService.brightIntoshID) }
                }
            }
            AppCard(bundleID: "com.velizard.NotchPilot", title: "NotchPilot", subtitle: "Right-click the island for the same menu") {
                ToggleChip(title: "Login", on: apps.launchAtLogin) { apps.toggleLaunchAtLogin() }
                ActionChip(symbol: "power", title: "Quit") { NSApp.terminate(nil) }
            }
        }
        .onAppear { apps.refresh() }
    }

    private var capturePop: some View {
        let r = AppsService.capturePop
        let running = apps.running.contains(r.bundleID)
        return AppCard(bundleID: r.bundleID, title: "CapturePop", subtitle: running ? nil : "Not running",
                       menuBarHidden: running ? apps.bool(r, "hideStatusItem") : nil,
                       toggleMenuBar: { apps.send(r, "setStatusItemHidden:\(!apps.bool(r, "hideStatusItem"))") }) {
            if running {
                ToggleChip(title: "On", on: apps.bool(r, "enabled")) { apps.send(r, "toggleEnabled") }
                ToggleChip(title: "Auto-copy", on: apps.bool(r, "autoCopy")) { apps.send(r, "toggleAutoCopy") }
                ToggleChip(title: "⇧⌘4", on: apps.bool(r, "customRegion")) { apps.send(r, "toggleCustomRegion") }
                ActionChip(symbol: "viewfinder", title: nil) { apps.send(r, "captureRegion") }
                ActionChip(symbol: "folder", title: nil) { apps.send(r, "openCapturesFolder") }
                ActionChip(symbol: "gearshape", title: nil) { apps.send(r, "openSettings") }
            } else {
                ActionChip(symbol: "play.fill", title: "Launch") { apps.openApp(r.bundleID) }
            }
        }
    }

    private var pixelClipboard: some View {
        let r = AppsService.pixelClipboard
        let running = apps.running.contains(r.bundleID)
        let s = apps.state(r)
        let receiverOn = (s["running"] as? Bool) ?? false
        let subtitle: String = !running ? "Not running"
            : receiverOn ? "Receiving" + ((s["port"] as? Int).map { " · port \($0)" } ?? "") : "Receiver stopped"
        return AppCard(bundleID: r.bundleID, title: "Pixel Clipboard", subtitle: subtitle,
                       menuBarHidden: running ? apps.bool(r, "hideStatusItem") : nil,
                       toggleMenuBar: { apps.send(r, "setStatusItemHidden:\(!apps.bool(r, "hideStatusItem"))") }) {
            if running {
                ActionChip(symbol: "tray", title: "Inbox") { apps.send(r, "openInbox") }
                ActionChip(symbol: "gearshape", title: "Pairing") { apps.send(r, "openSettings") }
            } else {
                ActionChip(symbol: "play.fill", title: "Launch") { apps.openApp(r.bundleID) }
            }
        }
    }
}

struct AppCard<Actions: View>: View {
    var bundleID: String
    var title: String
    var subtitle: String?
    /// nil = the app can't report it; true/false = its menu bar icon is hidden/shown.
    var menuBarHidden: Bool? = nil
    var toggleMenuBar: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @EnvironmentObject var apps: AppsService

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: apps.icon(bundleID)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            }
            .frame(width: 118, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) { actions() }
            if let hidden = menuBarHidden, let toggleMenuBar {
                Image(systemName: hidden ? "menubar.rectangle" : "menubar.dock.rectangle.badge.record")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(hidden ? 0.35 : 0.9))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMenuBar)
                    .help(hidden ? "Show its menu bar icon" : "Hide its menu bar icon")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

struct ToggleChip: View {
    var title: String
    var on: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .foregroundStyle(on ? Color.black : Color.white)
            .background(Capsule().fill(on ? Color.white : Color.white.opacity(hover ? 0.16 : 0.09)))
            .contentShape(Capsule())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { action() } }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: on)
    }
}

struct ActionChip: View {
    var symbol: String
    var title: String?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            if let title { Text(title).font(.system(size: 11, weight: .medium)) }
        }
        .padding(.horizontal, title == nil ? 0 : 9)
        .frame(minWidth: 26, minHeight: 26)
        .background(Capsule().fill(Color.white.opacity(hover ? 0.16 : 0.09)))
        .contentShape(Capsule())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture(perform: action)
    }
}
