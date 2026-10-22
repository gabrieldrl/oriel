import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's output volume and mute: the default output device's, as its volume keys and Control
/// Centre set them (docs/mac-sound-plan.md, rules 2 to 6). Read, set and listened to through Core
/// Audio; the listeners follow the default device as it changes (headphones plugged in, AirPlay).
///
/// A device with no volume control (an HDMI display, some USB interfaces) keeps a volume of Sill's
/// own (`ownVolume`): the device plays at it, and the Mac's keys do nothing to it. A device with no
/// mute control is muted by its volume going to 0 and back.
///
/// Main actor: every call and `onChange`. Core Audio's listener blocks run on `.main`.
@MainActor
final class MacVolume {
    struct State: Equatable {
        var volume: Double
        var muted: Bool
    }

    /// Called after the volume or mute changed, by Sill or on the Mac.
    var onChange: ((State) -> Void)?
    /// Called when the default output device changes (headphones, AirPlay), after the first.
    var onDeviceChange: (() -> Void)?

    private(set) var device: AudioObjectID = kAudioObjectUnknown
    /// Sill's own volume, for a device without one.
    private var ownVolume = 1.0
    /// Sill's own mute, for a device without one: the volume it had before, put back at unmute.
    private var ownMuted = false
    private var volumeBeforeOwnMute: Float32?
    private var listening = false
    private var last: State?

    private static var defaultOutput: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    /// The volume and mute as they stand.
    var state: State {
        let volume: Double
        if !hasVolume { volume = ownVolume }
        else if !hasMute, ownMuted, let before = volumeBeforeOwnMute { volume = Double(before) }
        else { volume = Double(readFloat(Self.volumeAddress) ?? 1) }
        return State(volume: volume, muted: hasMute ? readUInt32(Self.muteAddress) == 1 : ownMuted)
    }

    /// Starts following the default output device and its volume and mute.
    func start() {
        guard !listening else { return }
        listening = true
        var address = Self.defaultOutput
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultChanged)
        follow(Self.readDefaultDevice())
    }

    /// Sets the volume, 0…1.
    func setVolume(_ volume: Double) {
        let v = min(max(volume, 0), 1)
        if !hasVolume {
            ownVolume = v
        } else if !hasMute, ownMuted {
            volumeBeforeOwnMute = Float32(v)   // applied at unmute
        } else {
            write(Float32(v), Self.volumeAddress)
        }
        report()
    }

    /// Mutes or unmutes the output.
    func setMuted(_ muted: Bool) {
        if hasMute {
            write(UInt32(muted ? 1 : 0), Self.muteAddress)
        } else if muted != ownMuted {
            ownMuted = muted
            if hasVolume {
                if muted {
                    volumeBeforeOwnMute = readFloat(Self.volumeAddress)
                    write(Float32(0), Self.volumeAddress)
                } else {
                    write(volumeBeforeOwnMute ?? 1, Self.volumeAddress)
                    volumeBeforeOwnMute = nil
                }
            }
        }
        report()
    }

    /// The default output device's UID, for the tap's aggregate device (its clock).
    var deviceUID: String? {
        guard device != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    // MARK: Following the device

    private lazy var defaultChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        // Never MainActor.assumeIsolated in core code: under the CLI's dispatchMain it traps.
        Task { @MainActor in self?.follow(Self.readDefaultDevice()) }
    }
    private lazy var valueChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor in self?.report() }
    }

    private func follow(_ next: AudioObjectID) {
        guard next != device else { report(); return }
        let changed = device != kAudioObjectUnknown
        if device != kAudioObjectUnknown {
            var v = Self.volumeAddress, m = Self.muteAddress
            AudioObjectRemovePropertyListenerBlock(device, &v, .main, valueChanged)
            AudioObjectRemovePropertyListenerBlock(device, &m, .main, valueChanged)
        }
        device = next
        if device != kAudioObjectUnknown {
            var v = Self.volumeAddress, m = Self.muteAddress
            if hasVolume { AudioObjectAddPropertyListenerBlock(device, &v, .main, valueChanged) }
            if hasMute { AudioObjectAddPropertyListenerBlock(device, &m, .main, valueChanged) }
        }
        report()
        if changed { onDeviceChange?() }
    }

    private func report() {
        let now = state
        guard now != last else { return }
        last = now
        onChange?(now)
    }

    private static func readDefaultDevice() -> AudioObjectID {
        var address = defaultOutput
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : AudioObjectID(kAudioObjectUnknown)
    }

    private var hasVolume: Bool { settable(Self.volumeAddress) }
    private var hasMute: Bool { settable(Self.muteAddress) }

    private func settable(_ a: AudioObjectPropertyAddress) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var address = a
        guard AudioObjectHasProperty(device, &address) else { return false }
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &ok) == noErr && ok.boolValue
    }

    private func readFloat(_ a: AudioObjectPropertyAddress) -> Float32? {
        var address = a
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func readUInt32(_ a: AudioObjectPropertyAddress) -> UInt32? {
        var address = a
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func write<T: BitwiseCopyable>(_ value: T, _ a: AudioObjectPropertyAddress) {
        guard device != kAudioObjectUnknown else { return }
        var address = a
        var v = value
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<T>.size), &v)
        if status != noErr { print("Sound: the Mac's output did not take a change (\(status)).") }
    }
}
