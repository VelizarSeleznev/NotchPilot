import AppKit
import SwiftUI

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
    }
}

/// Everything the island shows, shared by all views.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let nowPlaying = NowPlayingService()
    lazy var sessions = SessionTracker(nowPlaying: nowPlaying)
    let outputs = OutputDeviceService()
    let mixer = MixerService()
    let toggles = QuickToggles()
    let apps = AppsService()
    lazy var remote = RemoteAPI(np: nowPlaying, sessions: sessions, outputs: outputs)

    private init() {}

    func start() {
        nowPlaying.start()
        _ = sessions
        outputs.start()
        mixer.start()
        toggles.refresh()
        apps.start()
        remote.start()
    }
}
