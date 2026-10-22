// SPDX-License-Identifier: GPL-3.0-or-later
// Kulaklık ses seviyesi
//
// macOS her ses çıkış cihazının seviyesini ayrı tutar. Burada yalnızca kulaklığın ses
// seviyesi okunup değiştirilir; Mac'in hoparlörü ya da diğer çıkışlar etkilenmez.
// Kulaklık o an ses çıkışı değilse bile seviyesi ayarlanabilir; çıkış olduğunda geçerli olur.

import Foundation
import CoreAudio
import AudioToolbox

final class EarbudVolume: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var volume: Float = 0.5   // 0…1

    private var deviceID: AudioDeviceID?
    private var listener: AudioObjectPropertyListenerBlock?

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    /// Adı verilen Bluetooth kulaklığın ses çıkışını bul ve takip etmeye başla
    func attach(toDeviceNamed name: String) {
        let found = EarbudVolume.findBluetoothOutput(named: name)
        guard found != deviceID else { readVolume(); return }
        detach()
        deviceID = found
        isAvailable = found != nil
        guard let id = found else { return }
        readVolume()
        // Kulaklık tuşlarıyla ya da klavyeden ses değişince kaydırıcı da güncellensin
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.readVolume() }
        }
        listener = block
        var addr = EarbudVolume.volumeAddress
        AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block)
    }

    func detach() {
        if let id = deviceID, let block = listener {
            var addr = EarbudVolume.volumeAddress
            AudioObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, block)
        }
        listener = nil
        deviceID = nil
        isAvailable = false
    }

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        guard let id = deviceID else { return }
        var addr = EarbudVolume.volumeAddress
        var v = volume
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    private func readVolume() {
        guard let id = deviceID else { return }
        var addr = EarbudVolume.volumeAddress
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr {
            volume = v
        }
    }

    // MARK: CoreAudio yardımcıları

    private static func findBluetoothOutput(named name: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }

        let target = name.lowercased()
        let candidates = ids.filter { transportType($0) == kAudioDeviceTransportTypeBluetooth && hasOutput($0) }
        return candidates.first { deviceName($0)?.lowercased() == target }
            ?? candidates.first { (deviceName($0)?.lowercased() ?? "").contains(target) }
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &type)
        return type
    }

    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }
}
