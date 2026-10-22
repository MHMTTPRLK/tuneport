// SPDX-License-Identifier: GPL-3.0-or-later
// Life P3 (A3939) durum paketi (komut 01 01) çözümleyicisi

import Foundation

enum AmbientMode: UInt8, CaseIterable {
    case noiseCanceling = 0, transparency = 1, normal = 2
}

enum NoiseCancelingMode: UInt8, CaseIterable {
    case transport = 0, outdoor = 1, indoor = 2
}

enum TransparencyMode: UInt8, CaseIterable {
    case full = 0, vocal = 1
}

struct ButtonSlot {
    var enabled: UInt8
    var action: UInt8
}

struct P3State {
    var batteryLeft: Int          // 0–5
    var batteryRight: Int
    var chargingLeft: Bool
    var chargingRight: Bool
    var firmwareLeft: String
    var firmwareRight: String
    var serial: String
    var eqProfile: UInt16         // 0xFEFE = özel
    var eqLeft: [UInt8]           // 10 bant, ham değer (dB*10 + 120)
    var eqRight: [UInt8]
    var buttons: [ButtonSlot]     // 6 adet: sol çift, sol uzun, sağ çift, sağ uzun, sol tek, sağ tek
    var modeCycle: UInt8          // bit0 ANC, bit1 Şeffaf, bit2 Normal
    var ambient: UInt8
    var noiseCanceling: UInt8
    var transparency: UInt8
    var customNoiseCanceling: UInt8
    var touchTone: UInt8?
    var gamingMode: UInt8?

    init?(_ b: [UInt8]) {
        guard b.count >= 125 else { return nil }
        var i = 0
        func take(_ n: Int) -> [UInt8] {
            defer { i += n }
            return Array(b[i..<(i + n)])
        }
        _ = take(2) // host cihaz, TWS durumu
        let bat = take(4)
        batteryLeft = Int(bat[0]); batteryRight = Int(bat[1])
        chargingLeft = bat[2] != 0; chargingRight = bat[3] != 0
        let fw = take(10)
        firmwareLeft = String(bytes: fw[0..<5], encoding: .ascii) ?? "?"
        firmwareRight = String(bytes: fw[5..<10], encoding: .ascii) ?? "?"
        serial = String(bytes: take(16), encoding: .ascii) ?? "?"
        let pid = take(2)
        eqProfile = UInt16(pid[0]) | (UInt16(pid[1]) << 8)
        eqLeft = take(10)
        eqRight = take(10)
        _ = take(1)   // yaş aralığı
        _ = take(48)  // HearID
        var slots: [ButtonSlot] = []
        for _ in 0..<6 {
            let x = take(2)
            slots.append(ButtonSlot(enabled: x[0], action: x[1]))
        }
        buttons = slots
        modeCycle = take(1)[0]
        let m = take(4)
        ambient = m[0]; noiseCanceling = m[1]; transparency = m[2]; customNoiseCanceling = m[3]
        _ = take(2)   // bilinmeyen
        if b.count >= i + 3 {
            let extra = take(3)
            touchTone = extra[0]
            gamingMode = extra[2]
        } else {
            touchTone = nil
            gamingMode = nil
        }
    }

    /// Bantlar dB cinsinden (ilk 8 bant)
    var eqDecibels: [Double] {
        eqLeft.prefix(8).map { (Double($0) - 120) / 10 }
    }

    /// İki kulaklıktan düşük olanın yüzdesi
    var lowestBatteryPercent: Int {
        min(min(batteryLeft, 5), min(batteryRight, 5)) * 20
    }
}
