import AppKit
import Foundation

/// Finds and drives media tabs in Chromium-family browsers over AppleScript.
/// Runs every script on one serial background queue.
enum BrowserBridge {
    struct Tab {
        var window: Int
        var index: Int
        var id: String
        var title: String
        var url: String
        var active: Bool
    }

    /// Browsers whose AppleScript dictionary has windows → tabs with `execute javascript`.
    static let supported: [String: String] = [
        "company.thebrowser.Browser": "Arc",
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.dia": "Dia",
    ]

    static let mediaHosts = [
        "deezer.", "youtube.", "youtu.be", "spotify.", "soundcloud.", "music.yandex", "vk.com", "vkvideo",
        "twitch.", "bandcamp.", "music.apple", "netflix.", "kinopoisk", "rutube.", "tidal.", "pandora.",
    ]

    private static let queue = DispatchQueue(label: "notchpilot.applescript")

    static func isBrowser(_ bundleID: String?) -> Bool {
        bundleID.map { supported[$0] != nil } ?? false
    }

    // MARK: - Script plumbing

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Log.write("AppleScript error: \(error[NSAppleScript.errorNumber] ?? "?") \(error[NSAppleScript.errorMessage] ?? "")") }
        return result
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func strings(_ d: NSAppleEventDescriptor?) -> [String] {
        guard let d, d.numberOfItems > 0 else { return [] }
        return (1...d.numberOfItems).map { d.atIndex($0)?.stringValue ?? "" }
    }

    // MARK: - Tabs

    /// All tabs of all windows, one Apple Event per property per window.
    static func listTabs(bundleID: String) -> [Tab] {
        let src = """
        tell application id \(quote(bundleID))
            set out to {}
            repeat with w in windows
                set end of out to {id of every tab of w, title of every tab of w, URL of every tab of w, id of active tab of w}
            end repeat
            return out
        end tell
        """
        guard let result = run(src), result.numberOfItems > 0 else { return [] }
        var tabs: [Tab] = []
        for wi in 1...result.numberOfItems {
            guard let w = result.atIndex(wi) else { continue }
            let ids = strings(w.atIndex(1)), titles = strings(w.atIndex(2)), urls = strings(w.atIndex(3))
            let activeID = w.atIndex(4)?.stringValue ?? ""
            for i in 0..<ids.count {
                tabs.append(Tab(window: wi, index: i + 1, id: ids[i],
                                title: i < titles.count ? titles[i] : "",
                                url: i < urls.count ? urls[i] : "",
                                active: ids[i] == activeID))
            }
        }
        return tabs
    }

    /// Runs JavaScript in a tab by position; sleeping tabs can hang, hence the timeout.
    static func execute(bundleID: String, tab: Tab, js: String, timeout: Int = 2) -> String? {
        let src = """
        tell application id \(quote(bundleID))
            with timeout of \(timeout) seconds
                return execute (tab \(tab.index) of window \(tab.window)) javascript \(quote(js))
            end timeout
        end tell
        """
        guard let raw = run(src)?.stringValue else { return nil }
        // Arc JSON-encodes the JavaScript result; Chrome returns it as is.
        if raw.hasPrefix("\""), let s = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) { return s }
        return raw
    }

    /// Re-locates a tab by id (positions shift when tabs are opened or closed).
    static func locate(bundleID: String, tabID: String) -> Tab? {
        listTabs(bundleID: bundleID).first { $0.id == tabID }
    }

    private static let probeJS = """
    (()=>{const m=navigator.mediaSession&&navigator.mediaSession.metadata;
    const els=[...document.querySelectorAll('video,audio')];
    return JSON.stringify({t:document.title,ms:m?m.title:'',ma:m?m.artist:'',
    playing:els.some(e=>!e.paused&&!e.ended)||navigator.mediaSession.playbackState==='playing'});})()
    """

    /// Finds the tab that is the source of the given now-playing title.
    /// Checks `preferred` first, then a handful of likely candidates.
    static func findMediaTab(bundleID: String, title: String, artist: String, preferred: String?) -> Tab? {
        let tabs = listTabs(bundleID: bundleID)
        guard !tabs.isEmpty else { return nil }
        let t = title.lowercased(), a = artist.lowercased()

        func score(_ tab: Tab) -> Int {
            var s = 0
            if tab.id == preferred { s += 100 }
            let lt = tab.title.lowercased()
            if !t.isEmpty, lt.contains(t) { s += 50 }
            if mediaHosts.contains(where: { tab.url.contains($0) }) { s += 20 }
            if tab.active { s += 5 }
            return s
        }
        Log.write("findMediaTab: \(tabs.count) tabs for '\(title)'")
        let candidates = tabs.map { ($0, score($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(10)

        var fallback: Tab?
        for (tab, _) in candidates {
            let json = execute(bundleID: bundleID, tab: tab, js: probeJS, timeout: 1)
            guard let json, let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                Log.write("  probe \(tab.window):\(tab.index) \(tab.url.prefix(60)) -> no result: \(json ?? "nil")")
                continue
            }
            let docTitle = (d["t"] as? String ?? "").lowercased()
            let msTitle = (d["ms"] as? String ?? "").lowercased()
            let playing = d["playing"] as? Bool ?? false
            Log.write("  probe \(tab.url.prefix(60)) -> \(json.prefix(160))")
            if !t.isEmpty, msTitle == t || docTitle.contains(t) { return tab }
            if playing, fallback == nil { fallback = tab }
            if !a.isEmpty, docTitle.contains(a), fallback == nil { fallback = tab }
        }
        return fallback
    }

    // MARK: - Actions

    /// Site-specific play buttons for players that keep their <audio> out of the DOM.
    private static let playJS = """
    (()=>{
    const click=s=>{const b=document.querySelector(s);if(b){b.click();return true}return false};
    const h=location.host;
    if(h.includes('deezer')&&click('[data-testid=play_button_play]'))return 'deezer';
    if(h.includes('spotify')){const b=document.querySelector('[data-testid=control-button-playpause]');
      if(b&&/play|воспр/i.test(b.getAttribute('aria-label')||'')){b.click();return 'spotify'}}
    if(h.includes('music.youtube')){const b=document.querySelector('#play-pause-button');
      if(b&&/play|воспр/i.test(b.getAttribute('title')||b.getAttribute('aria-label')||'')){b.click();return 'ytm'}}
    if(h.includes('soundcloud')&&click('.playControl:not(.playing)'))return 'sc';
    const els=[...document.querySelectorAll('video,audio')].filter(e=>e.duration>0);
    if(els.length){els.sort((a,b)=>b.currentTime-a.currentTime);els[0].play();return 'media'}
    if(navigator.mediaSession.playbackState==='paused'){
      const b=[...document.querySelectorAll('button[aria-label]')].find(b=>/^(play|воспроизвести)$/i.test(b.getAttribute('aria-label')));
      if(b){b.click();return 'button'}}
    return 'none';})()
    """

    private static let pauseJS = """
    (()=>{document.querySelectorAll('video,audio').forEach(e=>e.pause());
    const h=location.host;
    if(h.includes('deezer')){const b=document.querySelector('[data-testid=play_button_pause]');if(b)b.click();}
    return 'ok'})()
    """

    static func play(bundleID: String, tabID: String, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard let tab = locate(bundleID: bundleID, tabID: tabID) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let r = execute(bundleID: bundleID, tab: tab, js: playJS)
            DispatchQueue.main.async { completion(r != nil && r != "none") }
        }
    }

    static func pause(bundleID: String, tabID: String) {
        queue.async {
            guard let tab = locate(bundleID: bundleID, tabID: tabID) else { return }
            _ = execute(bundleID: bundleID, tab: tab, js: pauseJS)
        }
    }

    static func focus(bundleID: String, tabID: String) {
        queue.async {
            guard let tab = locate(bundleID: bundleID, tabID: tabID) else { return }
            let src: String
            if bundleID.hasPrefix("company.thebrowser") {
                src = """
                tell application id \(quote(bundleID))
                    tell tab \(tab.index) of window \(tab.window) to select
                    activate
                end tell
                """
            } else {
                src = """
                tell application id \(quote(bundleID))
                    set active tab index of window \(tab.window) to \(tab.index)
                    set index of window \(tab.window) to 1
                    activate
                end tell
                """
            }
            _ = run(src)
        }
    }

    static func async<T>(_ work: @escaping () -> T, then: @escaping (T) -> Void) {
        queue.async {
            let value = work()
            DispatchQueue.main.async { then(value) }
        }
    }

    /// Scriptable native players get a direct `play`; anything else is just brought forward.
    static func playApp(bundleID: String) {
        queue.async {
            if ["com.spotify.client", "com.apple.Music", "com.apple.podcasts"].contains(bundleID) {
                _ = run("tell application id \(quote(bundleID)) to play")
            } else {
                DispatchQueue.main.async {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
            }
        }
    }
}
