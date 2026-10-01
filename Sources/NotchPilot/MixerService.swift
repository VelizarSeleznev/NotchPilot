import AppKit
import AudioToolbox
import CoreAudio
import Darwin

/// An app that produces sound, possibly through several helper processes.
struct AudioApp: Identifiable, Equatable {
    var id: String            // bundle path or executable name
    var name: String
    var bundlePath: String?
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
    var volume: Float
    var muted: Bool
}

/// Per-app volume using Core Audio process taps (macOS 14.2+).
/// Apps at 100% are left untouched; others are captured, scaled and replayed.
@MainActor
final class MixerService: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var lastError: String?

    private var volumes: [String: Float] = [:]
    private var mutes: Set<String> = []
    private var taps: [String: AppTap] = [:]
    private var lastHeard: [String: Date] = [:]
    private var pollTimer: Timer?
    private var watchedProcesses: Set<AudioObjectID> = []
    private let ownPID = getpid()
    /// Lets Bluetooth headphones go when nothing audible plays (see BluetoothRelease).
    let release = BluetoothRelease()

    func start() {
        volumes = (UserDefaults.standard.dictionary(forKey: "mixer.volumes") as? [String: Float]) ?? [:]
        refreshProcesses()
        CA.listen(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            MainActor.assumeIsolated { self?.refreshProcesses() }
        }
        CA.listen(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            MainActor.assumeIsolated { self?.rebuildAllTaps() }
        }
        // Cheap: a property read per audio process. Keeps "who is playing" fresh.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshProcesses() }
        }
    }

    func refreshProcesses() {
        let objects = CA.array(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
        var grouped: [String: AudioApp] = [:]
        let now = Date()
        for obj in objects {
            let pid: pid_t = CA.get(obj, CA.address(kAudioProcessPropertyPID), default: -1)
            guard pid > 0, pid != ownPID else { continue }
            guard let owner = Self.owner(of: pid) else { continue }
            let running: UInt32 = CA.get(obj, CA.address(kAudioProcessPropertyIsRunningOutput), default: 0)
            if watchedProcesses.insert(obj).inserted {
                // Start/stop of playback reaches taps and the Bluetooth release without waiting for the poll.
                CA.listen(obj, CA.address(kAudioProcessPropertyIsRunningOutput)) { [weak self] in
                    MainActor.assumeIsolated { self?.refreshProcesses() }
                }
            }
            var app = grouped[owner.id] ?? AudioApp(
                id: owner.id, name: owner.name, bundlePath: owner.path, processObjects: [],
                isPlaying: false, volume: volumes[owner.id] ?? 1, muted: mutes.contains(owner.id)
            )
            app.processObjects.append(obj)
            if running != 0 {
                app.isPlaying = true
                lastHeard[owner.id] = now
            }
            grouped[owner.id] = app
        }
        // Show what is audible now, what was audible in the last minute, and anything adjusted.
        let visible = grouped.values.filter { app in
            app.isPlaying || (lastHeard[app.id].map { now.timeIntervalSince($0) < 60 } ?? false)
                || app.volume < 0.999 || app.muted
        }
        let sorted = visible.sorted {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if sorted != apps { apps = sorted }
        watchedProcesses.formIntersection(objects)
        syncTaps(with: grouped)
        for (id, tap) in taps { tap.setActive(grouped[id]?.isPlaying ?? false) }
        let playing = grouped.values.filter(\.isPlaying)
        release.update(anyOutput: !playing.isEmpty,
                       audibleOutput: playing.contains { effectiveGain($0.id) > 0.001 })
    }

    func setVolume(_ app: AudioApp, _ volume: Float) {
        volumes[app.id] = volume
        UserDefaults.standard.set(volumes, forKey: "mixer.volumes")
        if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].volume = volume }
        applyGain(app.id, processObjects: app.processObjects)
    }

    func toggleMute(_ app: AudioApp) {
        if mutes.contains(app.id) { mutes.remove(app.id) } else { mutes.insert(app.id) }
        if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].muted = mutes.contains(app.id) }
        applyGain(app.id, processObjects: app.processObjects)
    }

    private func effectiveGain(_ id: String) -> Float {
        mutes.contains(id) ? 0 : (volumes[id] ?? 1)
    }

    private func applyGain(_ id: String, processObjects: [AudioObjectID]) {
        let gain = effectiveGain(id)
        if gain >= 0.999 {
            taps.removeValue(forKey: id)?.invalidate()
            return
        }
        // A tap mutes only while it is read. Gain 0 reads it through the built-in speakers
        // (writing silence) so muted apps don't keep Bluetooth headphones busy.
        let replay = gain > 0.001
        if let tap = taps[id], Set(tap.processObjects) == Set(processObjects), tap.replays == replay {
            tap.gain = gain
            return
        }
        taps.removeValue(forKey: id)?.invalidate()
        let device = replay ? CA.defaultOutput : (BluetoothRelease.builtInSpeakers() ?? CA.defaultOutput)
        guard let outputUID = CA.string(device, kAudioDevicePropertyDeviceUID) else { return }
        do {
            let tap = try AppTap(processObjects: processObjects, outputUID: outputUID, replays: replay, name: id)
            tap.gain = gain
            tap.setActive(apps.first { $0.id == id }?.isPlaying ?? false)
            taps[id] = tap
            lastError = nil
        } catch {
            lastError = "\(error)"
            Log.write("mixer: \(error)")
        }
    }

    /// Recreate taps when an app gains/loses helper processes.
    private func syncTaps(with grouped: [String: AudioApp]) {
        for (id, tap) in taps {
            guard let app = grouped[id] else {
                tap.invalidate()
                taps[id] = nil
                continue
            }
            if Set(app.processObjects) != Set(tap.processObjects) {
                applyGain(id, processObjects: app.processObjects)
            }
        }
        for (id, app) in grouped where taps[id] == nil && effectiveGain(id) < 0.999 {
            applyGain(id, processObjects: app.processObjects)
        }
    }

    private func rebuildAllTaps() {
        let current = taps
        taps.removeAll()
        for (id, tap) in current {
            tap.invalidate()
            applyGain(id, processObjects: tap.processObjects)
        }
    }

    // MARK: - Process → app

    private struct Owner { var id: String; var name: String; var path: String? }
    private static var ownerCache: [pid_t: Owner?] = [:]

    /// Maps helper processes (e.g. "Browser Helper") to the outermost .app bundle.
    private static func owner(of pid: pid_t) -> Owner? {
        if let cached = ownerCache[pid] { return cached }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        var result: Owner?
        if len > 0 {
            let path = String(cString: buf)
            if let r = path.range(of: ".app/") {
                let bundle = String(path[..<r.lowerBound]) + ".app"
                let name = Bundle(path: bundle)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? Bundle(path: bundle)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                result = Owner(id: bundle, name: name, path: bundle)
            } else if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/") {
                // System daemons that only play UI sounds.
                result = nil
            } else {
                let name = (path as NSString).lastPathComponent
                result = Owner(id: path, name: name, path: nil)
            }
        }
        if ownerCache.count > 500 { ownerCache.removeAll() }
        ownerCache[pid] = result
        return result
    }
}

enum TapError: Error, CustomStringConvertible {
    case createTap(OSStatus), createAggregate(OSStatus), ioProc(OSStatus), start(OSStatus)
    var description: String {
        switch self {
        case .createTap(let s): return "Can't tap app audio (\(s)). Allow NotchPilot in Privacy → Screen & System Audio Recording."
        case .createAggregate(let s): return "Aggregate device failed (\(s))"
        case .ioProc(let s): return "IOProc failed (\(s))"
        case .start(let s): return "Device start failed (\(s))"
        }
    }
}

/// One process tap + private aggregate device that replays the app's audio with gain.
/// The tap mutes the app only while it is read, so the IOProc runs while the app plays
/// and stops otherwise: a running IOProc streams silence and keeps Bluetooth headphones
/// attached to the Mac.
final class AppTap: @unchecked Sendable {
    let processObjects: [AudioObjectID]
    let replays: Bool
    private var active = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let gainPtr = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    var gain: Float {
        get { gainPtr.pointee }
        set { gainPtr.pointee = max(0, min(newValue, 2)) }
    }

    /// `replays` false: mute only (gain 0), `outputUID` is just the clock that reads the tap.
    init(processObjects: [AudioObjectID], outputUID: String, replays: Bool, name: String) throws {
        self.processObjects = processObjects
        self.replays = replays
        gainPtr.pointee = 1

        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "NotchPilot \((name as NSString).lastPathComponent)"
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { throw TapError.createTap(status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchPilot Mixer",
            kAudioAggregateDeviceUIDKey: "com.velizard.NotchPilot.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            invalidate()
            throw TapError.createAggregate(status)
        }

        let gainPtr = self.gainPtr
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inData, _, outData, _ in
            AppTap.render(input: inData, output: outData, gain: gainPtr.pointee)
        }
        guard status == noErr else {
            invalidate()
            throw TapError.ioProc(status)
        }
    }

    func setActive(_ on: Bool) {
        guard on != active, aggregateID != kAudioObjectUnknown, let procID else { return }
        let status = on ? AudioDeviceStart(aggregateID, procID) : AudioDeviceStop(aggregateID, procID)
        if status == noErr { active = on } else { Log.write("mixer: replay \(on ? "start" : "stop") failed \(status)") }
    }

    /// Copies the tap (last input stream, stereo float) to every output channel, scaled.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        guard let src = ins.last, let srcData = src.mData?.assumingMemoryBound(to: Float.self) else {
            for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        let srcCh = max(Int(src.mNumberChannels), 1)
        let srcFrames = Int(src.mDataByteSize) / (4 * srcCh)
        for b in outs {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = max(Int(b.mNumberChannels), 1)
            let frames = Int(b.mDataByteSize) / (4 * ch)
            let n = min(frames, srcFrames)
            for f in 0..<n {
                for c in 0..<ch {
                    d[f * ch + c] = srcData[f * srcCh + (c % srcCh)] * gain
                }
            }
            if frames > n { memset(d + n * ch, 0, (frames - n) * ch * 4) }
        }
    }

    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                if active { AudioDeviceStop(aggregateID, procID) }
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        active = false
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        invalidate()
        gainPtr.deallocate()
    }
}
