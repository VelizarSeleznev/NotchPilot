import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Local API for companion processes (e.g. the Pixel Clipboard receiver bridging to a phone),
/// over DistributedNotificationCenter with the payload in `object` (a String).
///
/// Commands: post `com.velizard.NotchPilot.command` with one of
/// `play` `pause` `toggle` `next` `previous` `seek:<seconds>` `volume:<0...1>`
/// `volumeStep:<±delta>` `mute:toggle|true|false` `publishNowPlaying`.
///
/// State: `com.velizard.NotchPilot.nowPlaying`, JSON with title, artist, album, source,
/// playing, duration, elapsed (at sampledAt, unix seconds), rate, artworkKey, artworkPath
/// (JPEG, may be absent), volume (0...1 of the default output), muted, output, hasMedia.
/// Posted on every change (throttled) and in reply to `publishNowPlaying`.
@MainActor
final class RemoteAPI {
    static let commandName = Notification.Name("com.velizard.NotchPilot.command")
    static let stateName = Notification.Name("com.velizard.NotchPilot.nowPlaying")

    private let np: NowPlayingService
    private let sessions: SessionTracker
    private let outputs: OutputDeviceService
    private let center = DistributedNotificationCenter.default()
    private var bag: Set<AnyCancellable> = []
    private var watchedDevice: AudioDeviceID = 0
    private var pending: DispatchWorkItem?
    private var lastPosted = ""
    private var writtenArtworkKey = ""
    private let artworkDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.velizard.NotchPilot", isDirectory: true)

    init(np: NowPlayingService, sessions: SessionTracker, outputs: OutputDeviceService) {
        self.np = np
        self.sessions = sessions
        self.outputs = outputs
    }

    func start() {
        center.addObserver(forName: Self.commandName, object: nil, queue: .main) { [weak self] note in
            guard let action = note.object as? String else { return }
            MainActor.assumeIsolated { self?.handle(action) }
        }
        np.$info.sink { [weak self] _ in self?.schedulePublish() }.store(in: &bag)
        np.$artwork.sink { [weak self] _ in self?.schedulePublish() }.store(in: &bag)
        outputs.$currentID.sink { [weak self] id in
            self?.watchVolume(of: id)
            self?.schedulePublish()
        }.store(in: &bag)
    }

    // MARK: Commands

    private func handle(_ action: String) {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "play": np.send(.play)
        case "pause": np.send(.pause)
        case "toggle": np.send(.toggle)
        case "next": np.send(.next)
        case "previous": np.send(.previous)
        case "seek": if let s = Double(arg) { np.seek(to: s) }
        case "volume": if let v = Double(arg) { setVolume(Float(v)) }
        case "volumeStep": if let d = Double(arg) { setVolume(volume + Float(d)) }
        case "mute":
            let target = arg == "toggle" ? !muted : arg == "true"
            _ = CA.set(CA.defaultOutput, CA.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(target ? 1 : 0))
        case "publishNowPlaying": publish(force: true); return
        default: Log.write("remote: unknown command \(action)"); return
        }
        schedulePublish()
    }

    // MARK: Volume of the default output

    private var volumeAddress: AudioObjectPropertyAddress {
        CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
    }

    var volume: Float {
        var addr = volumeAddress
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioHardwareServiceGetPropertyData(CA.defaultOutput, &addr, 0, nil, &size, &v) == noErr else { return 0 }
        return v
    }

    var muted: Bool {
        CA.get(CA.defaultOutput, CA.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), default: UInt32(0)) != 0
    }

    private func setVolume(_ value: Float) {
        var addr = volumeAddress
        var v = Float32(min(max(value, 0), 1))
        let status = AudioHardwareServiceSetPropertyData(CA.defaultOutput, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if status != noErr { Log.write("remote: set volume failed \(status)") }
        if v > 0, muted {
            _ = CA.set(CA.defaultOutput, CA.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(0))
        }
    }

    private func watchVolume(of device: AudioDeviceID) {
        guard device != 0, device != watchedDevice else { return }
        watchedDevice = device
        // Listeners on old devices stay harmless: they only schedule a publish of the current state.
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            CA.listen(device, CA.address(selector, kAudioObjectPropertyScopeOutput)) { [weak self] in
                MainActor.assumeIsolated { self?.schedulePublish() }
            }
        }
    }

    // MARK: State

    private func schedulePublish() {
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
                self?.publish(force: false)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func publish(force: Bool) {
        let info = np.info
        var state: [String: Any] = [
            "hasMedia": info != nil,
            "volume": Double(volume),
            "muted": muted,
            "output": outputs.current?.name ?? "",
        ]
        if let info {
            state["title"] = info.title
            state["artist"] = info.artist
            state["album"] = info.album
            state["source"] = sessions.current?.sourceLabel ?? ""
            state["playing"] = info.playing
            state["duration"] = info.duration
            state["rate"] = info.rate
            state["artworkKey"] = info.artworkKey
            if let path = artworkPath(for: info.artworkKey) { state["artworkPath"] = path }
        }
        // Compare without the moving position so ticks don't re-post.
        guard let stable = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys),
              let stableString = String(data: stable, encoding: .utf8) else { return }
        if let info {
            state["elapsed"] = info.position()
            state["sampledAt"] = Date().timeIntervalSince1970
        }
        let seekChanged = info.map { abs($0.elapsed - lastElapsed) > 0.01 } ?? false
        lastElapsed = info?.elapsed ?? 0
        guard force || stableString != lastPosted || seekChanged else { return }
        lastPosted = stableString
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8) else { return }
        center.postNotificationName(Self.stateName, object: json, userInfo: nil, deliverImmediately: true)
    }

    private var lastElapsed: Double = 0

    /// Current artwork as a JPEG in Caches, rewritten only when the key changes.
    private func artworkPath(for key: String) -> String? {
        guard !key.isEmpty, let image = np.artwork else { return nil }
        let url = artworkDir.appendingPathComponent("artwork.jpg")
        if writtenArtworkKey != key {
            guard let data = image.jpegData else { return nil }
            try? FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
            writtenArtworkKey = key
        }
        return url.path
    }
}
