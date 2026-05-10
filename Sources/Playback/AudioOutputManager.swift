import Foundation
import CoreAudio
import AudioToolbox
import Combine

/// One entry in the list of available CoreAudio output devices.
struct AudioOutputDevice: Identifiable, Hashable {
    /// CoreAudio AudioObjectID. Stable for the duration of a connection;
    /// not stable across reboots — use `uid` for persistence.
    var id: AudioObjectID
    /// CoreAudio device UID (e.g. "AppleUSBAudioEngine:Focusrite:Scarlett 4i4 USB:…").
    /// Stable across reboots and reconnections — used as the persistence key.
    var uid: String
    /// Human-readable name ("Focusrite USB", "MacBook Pro Speakers").
    var name: String
    /// Total output channel count across all output streams.
    var channelCount: Int
}

/// Tracks the set of available CoreAudio output devices and the user's
/// current selection. Engine wiring (actually pushing audio at the
/// selected device) is the responsibility of `PlaybackEngine`.
final class AudioOutputManager: ObservableObject {
    static let shared = AudioOutputManager()

    @Published private(set) var devices: [AudioOutputDevice] = []
    /// UID of the currently chosen output device. nil = follow the system
    /// default output. Persisted across launches.
    @Published var currentUID: String? {
        didSet {
            UserDefaults.standard.set(currentUID, forKey: kCurrentUIDKey)
            ensureMappingForCurrent()
        }
    }

    private let kCurrentUIDKey = "audioOutputDeviceUID"
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    init() {
        self.currentUID = UserDefaults.standard.string(forKey: kCurrentUIDKey)
        refresh()
        installDeviceListListener()
        ensureMappingForCurrent()
    }

    deinit {
        removeDeviceListListener()
    }

    // MARK: - Lookup

    var currentDevice: AudioOutputDevice? {
        if let uid = currentUID {
            return devices.first { $0.uid == uid } ?? systemDefaultDevice()
        }
        return systemDefaultDevice()
    }

    /// Channel count of the currently selected device, or 2 as a fallback
    /// when no device is connected (so the UI doesn't show wild ranges).
    var currentChannelCount: Int {
        currentDevice?.channelCount ?? 2
    }

    // MARK: - Refresh

    /// Re-enumerates connected output devices. Called on init and whenever
    /// CoreAudio fires a device-list change.
    func refresh() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr,
              size > 0 else {
            self.devices = []
            return
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &addr, 0, nil, &size, buf.baseAddress!)
        }
        guard status == noErr else { return }

        var result: [AudioOutputDevice] = []
        for id in ids {
            let chan = outputChannelCount(of: id)
            guard chan > 0 else { continue }
            guard let name = stringProperty(id, selector: kAudioObjectPropertyName) else { continue }
            let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? "id-\(id)"
            result.append(AudioOutputDevice(id: id, uid: uid, name: name, channelCount: chan))
        }
        // Keep order roughly stable; sort alphabetically for predictability.
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.devices = result
        ensureMappingForCurrent()
    }

    // MARK: - Mapping bootstrap

    /// Whenever the current device changes (or the device list refreshes),
    /// make sure `OutputBusStore` has a mapping row for it so the editor
    /// has somewhere to put assignments.
    private func ensureMappingForCurrent() {
        guard let dev = currentDevice else { return }
        OutputBusStore.shared.ensureMapping(deviceUID: dev.uid,
                                            deviceName: dev.name,
                                            channelCount: dev.channelCount)
    }

    // MARK: - CoreAudio helpers

    private func systemDefaultDevice() -> AudioOutputDevice? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return devices.first { $0.id == deviceID }
    }

    private func outputChannelCount(of device: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(
            capacity: Int(size) / MemoryLayout<AudioBufferList>.size + 1
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, bufferList) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        var total = 0
        for buf in abl { total += Int(buf.mNumberChannels) }
        return total
    }

    private func stringProperty(_ device: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cfStr as String
    }

    // MARK: - Device-list change notifications

    private func installDeviceListListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
        if status == noErr { self.deviceListListener = block }
    }

    private func removeDeviceListListener() {
        guard let block = deviceListListener else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
    }
}
