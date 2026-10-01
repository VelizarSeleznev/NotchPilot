import CoreAudio
import Foundation

/// Multipoint headphones (XM5 and friends) stay with the Mac while any audio IO runs on
/// them, silence included. When the only apps playing are muted in the mixer (a game that
/// never stops its audio engine), move the default output to the muted built-in speakers
/// so the headphones can follow the phone; move back as soon as something audible plays.
///
/// Off switch: `defaults write com.velizard.NotchPilot release.enabled -bool false`
@MainActor
final class BluetoothRelease {
    static let idleSeconds: TimeInterval = 5

    private struct Parked: Codable {
        var headphonesUID: String
        var speakersUID: String
        var speakersWereMuted: Bool
        /// Back on the headphones, waiting to unmute the speakers.
        var returning = false
    }

    private static let stateKey = "release.parked"
    private var parked: Parked? {
        didSet {
            UserDefaults.standard.set(parked.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.stateKey)
        }
    }
    private var silentSince: Date?
    /// Default output we set ourselves; any other change means the user picked a device.
    private var expectedDefault: AudioDeviceID?

    private var enabled: Bool { UserDefaults.standard.object(forKey: "release.enabled") as? Bool ?? true }

    init() {
        parked = UserDefaults.standard.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode(Parked.self, from: $0) }
        // Quit halfway back: finish restoring the speakers.
        if parked?.returning == true { finishReturn() }
        CA.listen(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            MainActor.assumeIsolated { self?.defaultChanged() }
        }
    }

    var isParked: Bool { parked != nil }

    /// - anyOutput: some app runs audio output (its own IO, muted or not).
    /// - audibleOutput: one of those is not muted in the mixer.
    func update(anyOutput: Bool, audibleOutput: Bool) {
        if let p = parked {
            if p.returning { return }
            if audibleOutput || !enabled { unpark() }
            return
        }
        guard enabled, anyOutput, !audibleOutput, Self.isBluetooth(CA.defaultOutput) else {
            silentSince = nil
            return
        }
        let now = Date()
        guard let since = silentSince else {
            silentSince = now
            return
        }
        if now.timeIntervalSince(since) >= Self.idleSeconds { park() }
    }

    private func park() {
        silentSince = nil
        let headphones = CA.defaultOutput
        guard let headphonesUID = CA.string(headphones, kAudioDevicePropertyDeviceUID),
              let speakers = Self.builtInSpeakers(),
              let speakersUID = CA.string(speakers, kAudioDevicePropertyDeviceUID) else { return }
        let wasMuted = Self.mute(of: speakers)
        Self.setMute(speakers, true)
        parked = Parked(headphonesUID: headphonesUID, speakersUID: speakersUID, speakersWereMuted: wasMuted)
        setDefault(speakers)
        Log.write("release: only muted apps play; parked on muted speakers so headphones can switch")
    }

    private func unpark() {
        guard let p = parked, !p.returning else { return }
        parked?.returning = true
        if let headphones = Self.device(uid: p.headphonesUID), CA.defaultOutput != headphones {
            setDefault(headphones)
            Log.write("release: audible playback, back to headphones")
        }
        // Let players follow the new default before the speakers can make a sound.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.finishReturn() }
        }
    }

    private func finishReturn() {
        guard let p = parked else { return }
        parked = nil
        if !p.speakersWereMuted, let speakers = Self.device(uid: p.speakersUID) { Self.setMute(speakers, false) }
    }

    private func defaultChanged() {
        let current = CA.defaultOutput
        if let expected = expectedDefault, expected == current { return }
        expectedDefault = nil
        silentSince = nil
        // The user picked an output while parked: forget the park, give the speakers their sound back.
        guard let p = parked else { return }
        parked = nil
        if !p.speakersWereMuted, let speakers = Self.device(uid: p.speakersUID) { Self.setMute(speakers, false) }
        Log.write("release: output changed by user, park cancelled")
    }

    private func setDefault(_ device: AudioDeviceID) {
        expectedDefault = device
        _ = CA.set(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), device)
    }

    // MARK: - Devices

    private static func transport(_ device: AudioDeviceID) -> UInt32 {
        CA.get(device, CA.address(kAudioDevicePropertyTransportType), default: 0)
    }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        let t = transport(device)
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }

    static func builtInSpeakers() -> AudioDeviceID? {
        CA.array(CA.system, CA.address(kAudioHardwarePropertyDevices), of: AudioDeviceID.self).first {
            transport($0) == kAudioDeviceTransportTypeBuiltIn && CA.outputChannelCount($0) > 0
        }
    }

    private static func device(uid: String) -> AudioDeviceID? {
        CA.array(CA.system, CA.address(kAudioHardwarePropertyDevices), of: AudioDeviceID.self).first {
            CA.string($0, kAudioDevicePropertyDeviceUID) == uid
        }
    }

    private static let muteAddress = CA.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)

    private static func mute(of device: AudioDeviceID) -> Bool {
        CA.get(device, muteAddress, default: UInt32(0)) != 0
    }

    private static func setMute(_ device: AudioDeviceID, _ on: Bool) {
        _ = CA.set(device, muteAddress, UInt32(on ? 1 : 0))
    }
}
