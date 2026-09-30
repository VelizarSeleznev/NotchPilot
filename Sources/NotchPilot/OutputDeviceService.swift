import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Equatable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var transport: UInt32

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    var symbol: String {
        if isBluetooth { return name.localizedCaseInsensitiveContains("airpods") ? "airpodspro" : "headphones" }
        if isBuiltIn { return "laptopcomputer" }
        switch transport {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker"
        default: return "speaker.wave.2"
        }
    }
}

@MainActor
final class OutputDeviceService: ObservableObject {
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var currentID: AudioDeviceID = 0

    var current: OutputDevice? { devices.first { $0.id == currentID } }

    func start() {
        reload()
        CA.listen(CA.system, CA.address(kAudioHardwarePropertyDevices)) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        CA.listen(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        let ids = CA.array(CA.system, CA.address(kAudioHardwarePropertyDevices), of: AudioDeviceID.self)
        devices = ids.compactMap { id in
            guard CA.outputChannelCount(id) > 0 else { return nil }
            let transport: UInt32 = CA.get(id, CA.address(kAudioDevicePropertyTransportType), default: 0)
            // Only headphones and the laptop's own speakers; virtual/HDMI/AirPlay devices are noise here.
            let wanted = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE]
            guard wanted.contains(transport) else { return nil }
            let uid = CA.string(id, kAudioDevicePropertyDeviceUID) ?? ""
            let name = CA.string(id, kAudioObjectPropertyName) ?? "Output"
            let hidden: UInt32 = CA.get(id, CA.address(kAudioDevicePropertyIsHidden), default: 0)
            if hidden != 0 { return nil }
            return OutputDevice(id: id, uid: uid, name: name, transport: transport)
        }
        // Headphones first, then built-in speakers.
        devices.sort { rank($0) < rank($1) }
        currentID = CA.defaultOutput
    }

    private func rank(_ d: OutputDevice) -> Int {
        d.isBluetooth ? 0 : d.isBuiltIn ? 1 : 2
    }

    func select(_ device: OutputDevice) {
        _ = CA.set(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), device.id)
        // Keep system sounds on the same device.
        _ = CA.set(CA.system, CA.address(kAudioHardwarePropertyDefaultSystemOutputDevice), device.id)
        currentID = device.id
    }

    /// One-tap toggle: headphones <-> laptop speakers (or the next device).
    func cycle() {
        guard devices.count > 1 else { return }
        let i = devices.firstIndex { $0.id == currentID } ?? -1
        select(devices[(i + 1) % devices.count])
    }
}
