// SPDX-License-Identifier: GPL-3.0-or-later
// Mikrofon koruması
//
// Bir uygulama Bluetooth kulaklığın mikrofonunu açtığı anda kulaklık "telefon görüşmesi"
// profiline (HFP) geçer ve müzik mono, düşük kaliteye düşer. Bu, Bluetooth'un kendisinden
// gelen bir sınır; kulaklık ayarıyla değiştirilemez.
// Çözüm: Sistem varsayılan mikrofonunu Mac'in kendi mikrofonunda tutmak. Böylece kulaklık
// yüksek kaliteli (A2DP) modda kalır, aramalarda Mac'in mikrofonu kullanılır.

import Foundation
import CoreAudio

final class AudioInputGuard {
    var isEnabled: Bool {
        didSet { if isEnabled { enforce() } }
    }
    private(set) var lastSwitchDate: Date?

    init(enabled: Bool) {
        isEnabled = enabled
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.enforce()
        }
        enforce()
    }

    /// Varsayılan mikrofon bir Bluetooth cihazıysa Mac'in dahili mikrofonuna geçir.
    func enforce() {
        guard isEnabled,
              let current = AudioInputGuard.defaultInputDevice(),
              AudioInputGuard.transportType(current) == kAudioDeviceTransportTypeBluetooth,
              let builtIn = AudioInputGuard.builtInInputDevice(),
              builtIn != current else { return }
        if AudioInputGuard.setDefaultInputDevice(builtIn) {
            lastSwitchDate = Date()
        }
    }

    // MARK: CoreAudio yardımcıları

    private static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return r == noErr && id != 0 ? id : nil
    }

    private static func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &device) == noErr
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

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func builtInInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }
}
