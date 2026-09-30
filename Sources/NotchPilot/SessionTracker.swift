import AppKit
import Combine
import Foundation

/// One thing that played: a browser tab or a native app.
struct MediaSession: Identifiable, Codable, Equatable {
    var id: String
    var bundleID: String
    var tabID: String?
    var title: String
    var artist: String
    var host: String?
    var artworkData: Data?
    var playedSeconds: Double
    var lastActive: Date

    var appName: String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    var sourceLabel: String {
        if let host, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return appName
    }
}

/// Remembers media that actually got listened to, so the island can offer
/// "resume that other thing" without scanning every tab.
@MainActor
final class SessionTracker: ObservableObject {
    /// A session enters the switcher only after this much real playback.
    static let significantSeconds: Double = 30
    static let maxRemembered = 8

    @Published private(set) var sessions: [MediaSession] = []
    @Published private(set) var currentID: String?

    private let nowPlaying: NowPlayingService
    private var cancellables: Set<AnyCancellable> = []
    private var lastKey: String?
    private var resolving = false
    private var tick: Timer?
    private let storeKey = "sessions.v1"

    init(nowPlaying: NowPlayingService) {
        self.nowPlaying = nowPlaying
        load()
        nowPlaying.$info
            .receive(on: RunLoop.main)
            .sink { [weak self] info in self?.update(info) }
            .store(in: &cancellables)
        nowPlaying.$artwork
            .receive(on: RunLoop.main)
            .sink { [weak self] img in self?.attachArtwork(img) }
            .store(in: &cancellables)
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.accumulate() }
        }
    }

    var current: MediaSession? { sessions.first { $0.id == currentID } }

    /// Sessions offered for switching: significant ones other than the current.
    var others: [MediaSession] {
        sessions
            .filter { $0.id != currentID && $0.playedSeconds >= Self.significantSeconds }
            .sorted { $0.lastActive > $1.lastActive }
    }

    // MARK: - Tracking

    private func update(_ info: NowPlayingInfo?) {
        guard let info else { return }
        let app = NSRunningApplication(processIdentifier: info.pid)
        let bundleID = app?.bundleIdentifier ?? "pid.\(info.pid)"
        let key = "\(bundleID)|\(info.title)|\(info.artist)"
        guard key != lastKey else { return }
        lastKey = key

        if BrowserBridge.isBrowser(bundleID) {
            resolveTab(bundleID: bundleID, info: info)
        } else {
            upsert(id: "app:\(bundleID)", bundleID: bundleID, tabID: nil, host: nil, info: info)
        }
    }

    private func resolveTab(bundleID: String, info: NowPlayingInfo) {
        // The card shows NowPlaying directly; the session is only attributed once the tab is known.
        let preferred = current.flatMap { $0.bundleID == bundleID ? $0.tabID : nil }
        resolving = true
        let title = info.title, artist = info.artist
        BrowserBridge.async({
            BrowserBridge.findMediaTab(bundleID: bundleID, title: title, artist: artist, preferred: preferred)
        }, then: { [weak self] tab in
            guard let self else { return }
            self.resolving = false
            // A newer track may have arrived meanwhile; only apply if still current.
            guard let latest = self.nowPlaying.info, latest.title == title else { return }
            if let tab {
                let host = URL(string: tab.url)?.host
                // Carry over play time counted while the tab was still unknown.
                let fallbackID = "app:\(bundleID)"
                let carried = self.sessions.first { $0.id == fallbackID && $0.title == latest.title }?.playedSeconds ?? 0
                self.sessions.removeAll { $0.id == fallbackID }
                self.upsert(id: "tab:\(bundleID):\(tab.id)", bundleID: bundleID, tabID: tab.id, host: host, info: latest)
                if carried > 0, var s = self.current {
                    s.playedSeconds += carried
                    self.replace(s)
                }
            } else if self.current?.bundleID != bundleID {
                self.upsert(id: "app:\(bundleID)", bundleID: bundleID, tabID: nil, host: nil, info: latest)
            }
        })
    }

    private func upsert(id: String, bundleID: String, tabID: String?, host: String?, info: NowPlayingInfo) {
        var s = sessions.first { $0.id == id } ?? MediaSession(
            id: id, bundleID: bundleID, tabID: tabID, title: info.title, artist: info.artist,
            host: host, artworkData: nil, playedSeconds: 0, lastActive: Date()
        )
        s.title = info.title
        s.artist = info.artist
        s.host = host ?? s.host
        s.lastActive = Date()
        if let img = nowPlaying.artwork { s.artworkData = img.jpegData }
        replace(s)
        currentID = id
        trim()
        save()
    }

    private func attachArtwork(_ img: NSImage?) {
        guard let img, !resolving, let id = currentID, var s = sessions.first(where: { $0.id == id }) else { return }
        s.artworkData = img.jpegData
        replace(s)
    }

    private func accumulate() {
        guard let info = nowPlaying.info, info.playing, !resolving,
              let id = currentID, var s = sessions.first(where: { $0.id == id }) else { return }
        s.playedSeconds += 1
        s.lastActive = Date()
        replace(s)
        if Int(s.playedSeconds) % 15 == 0 { save() }
    }

    private func replace(_ s: MediaSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
    }

    private func trim() {
        let keep = sessions.sorted { $0.lastActive > $1.lastActive }.prefix(Self.maxRemembered)
        sessions = sessions.filter { s in keep.contains { $0.id == s.id } }
    }

    // MARK: - Actions

    /// Pause whatever plays now, then resume the chosen session.
    func switchTo(_ target: MediaSession) {
        if nowPlaying.info?.playing == true {
            nowPlaying.send(.pause)
        }
        if let tabID = target.tabID {
            // Browsers route media keys to one session; also pause the current tab directly
            // when it lives in the same browser, so two tabs never play at once.
            if let cur = current, let curTab = cur.tabID, cur.bundleID == target.bundleID, curTab != tabID {
                BrowserBridge.pause(bundleID: cur.bundleID, tabID: curTab)
            }
            BrowserBridge.play(bundleID: target.bundleID, tabID: tabID) { [weak self] ok in
                if !ok { self?.open(target) }
            }
        } else {
            BrowserBridge.playApp(bundleID: target.bundleID)
        }
        if var s = sessions.first(where: { $0.id == target.id }) {
            s.lastActive = Date()
            replace(s)
        }
    }

    func open(_ session: MediaSession) {
        if let tabID = session.tabID {
            BrowserBridge.focus(bundleID: session.bundleID, tabID: tabID)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: session.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func forget(_ session: MediaSession) {
        sessions.removeAll { $0.id == session.id }
        save()
    }

    /// Drops sessions whose tab or app is gone.
    func pruneClosedTabs() {
        let byBrowser = Dictionary(grouping: sessions.filter { $0.tabID != nil }, by: \.bundleID)
        for (bundleID, list) in byBrowser {
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            guard running else { continue }
            BrowserBridge.async({ Set(BrowserBridge.listTabs(bundleID: bundleID).map(\.id)) }, then: { [weak self] ids in
                guard let self, !ids.isEmpty else { return }
                let gone = list.filter { !ids.contains($0.tabID!) && $0.id != self.currentID }.map(\.id)
                if !gone.isEmpty {
                    self.sessions.removeAll { gone.contains($0.id) }
                    self.save()
                }
            })
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([MediaSession].self, from: data) else { return }
        sessions = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}

extension NSImage {
    var jpegData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
