import CoreAudio
import Foundation

/// Thin helpers over the CoreAudio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default value: T) -> T {
        var addr = addr
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? result : value
    }

    static func array<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, of: T.Type) -> [T] {
        var addr = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: count) { buf, n in
            let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buf.baseAddress!)
            n = status == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func set<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var addr = addr
        var value = value
        return AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    /// Calls `block` on the main queue whenever the property changes.
    @discardableResult
    static func listen(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ block: @escaping () -> Void) -> Bool {
        var addr = addr
        return AudioObjectAddPropertyListenerBlock(object, &addr, .main) { _, _ in block() } == noErr
    }

    static var defaultOutput: AudioDeviceID {
        return CA.get(system, address(kAudioHardwarePropertyDefaultOutputDevice), default: AudioDeviceID(0))
    }

    static func outputChannelCount(_ device: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
