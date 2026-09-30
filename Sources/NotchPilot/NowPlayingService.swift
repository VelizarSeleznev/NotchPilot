import AppKit
import Foundation

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var elapsed: Double
    var timestamp: Date
    var rate: Double
    var playing: Bool
    var pid: pid_t
    var artworkKey: String

    /// Current position, extrapolated from the last report.
    func position(at now: Date = Date()) -> Double {
        guard playing else { return elapsed }
        let p = elapsed + now.timeIntervalSince(timestamp) * max(rate, 1)
        return duration > 0 ? min(p, duration) : p
    }
}

/// Talks to the system Now Playing (MediaRemote) through the perl-hosted bridge,
/// because macOS 15.4+ only answers Apple-signed processes.
@MainActor
final class NowPlayingService: ObservableObject {
    enum Command: Int { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

    @Published private(set) var info: NowPlayingInfo?
    @Published private(set) var artwork: NSImage?
    private(set) var artworkCache: [String: NSImage] = [:]

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 1

    func start() {
        guard process == nil,
              let script = Bundle.main.url(forResource: "np_bridge", withExtension: "pl"),
              let dylib = Bundle.main.url(forResource: "libnp_bridge", withExtension: "dylib")
        else {
            NSLog("NotchPilot: bridge resources missing")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, dylib.path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.bridgeDied() }
        }
        do {
            try p.run()
            process = p
            input = inp.fileHandleForWriting
        } catch {
            NSLog("NotchPilot: bridge failed to start: \(error)")
        }
    }

    private func bridgeDied() {
        process = nil
        input = nil
        buffer.removeAll()
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.start() }
    }

    func send(_ command: Command) {
        write("cmd \(command.rawValue)\n")
        // Optimistic update so the button flips immediately.
        if var i = info {
            switch command {
            case .play: i.playing = true
            case .pause: i.playing = false
            case .toggle: i.playing.toggle()
            default: return
            }
            i.elapsed = info!.position()
            i.timestamp = Date()
            info = i
        }
    }

    func seek(to seconds: Double) {
        write("seek \(seconds)\n")
        if var i = info {
            i.elapsed = seconds
            i.timestamp = Date()
            info = i
        }
    }

    private func write(_ line: String) {
        try? input?.write(contentsOf: Data(line.utf8))
    }

    private func consume(_ data: Data) {
        if data.isEmpty { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(obj)
            }
        }
    }

    private func handle(_ d: [String: Any]) {
        restartDelay = 1
        let key = d["artworkKey"] as? String ?? ""
        if let b64 = d["artwork"] as? String, let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
            artworkCache[key] = img
            if artworkCache.count > 40 { artworkCache.removeAll(); artworkCache[key] = img }
        }
        let title = d["Title"] as? String ?? ""
        guard !title.isEmpty else {
            info = nil
            artwork = nil
            return
        }
        let playing = (d["playing"] as? NSNumber)?.boolValue ?? false
        let ts = (d["Timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        let new = NowPlayingInfo(
            title: title,
            artist: d["Artist"] as? String ?? "",
            album: d["Album"] as? String ?? "",
            duration: d["Duration"] as? Double ?? 0,
            elapsed: d["ElapsedTime"] as? Double ?? 0,
            timestamp: ts,
            rate: d["PlaybackRate"] as? Double ?? (playing ? 1 : 0),
            playing: playing,
            pid: pid_t((d["pid"] as? Int) ?? 0),
            artworkKey: key
        )
        if new != info { info = new }
        let img = key.isEmpty ? nil : artworkCache[key]
        if img !== artwork { artwork = img }
    }
}
