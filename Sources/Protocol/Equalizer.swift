// SPDX-License-Identifier: GPL-3.0-or-later
// EQ hazır profilleri ve DRC hesabı
//
// Önemli bulgu: Life P3, EQ'yu ses işlemcisine yalnızca DRC eğrisiyle birlikte
// gönderildiğinde (komut 02 83) uyguluyor. 02 81 komutunu kabul edip kaydediyor
// ama sese yansıtmıyor.

import Foundation

struct EQPreset: Identifiable {
    let id: UInt16
    let name: String
    let values: [Int]   // 10 bant, 0.1 dB birimi
}

enum Equalizer {
    static let customProfileID: UInt16 = 0xFEFE
    static let bandLabels = ["100", "200", "400", "800", "1.6k", "3.2k", "6.4k", "12.8k"]
    static let range: ClosedRange<Double> = -12...13.5

    // Resmi uygulamadaki 22 profil, aynı ID'lerle
    static let presets: [EQPreset] = [
        EQPreset(id: 0x0000, name: "Soundcore Signature", values: [0, 0, 0, 0, 0, 0, 0, 0, 0, -120]),
        EQPreset(id: 0x0001, name: "Acoustic",          values: [40, 10, 20, 20, 40, 40, 40, 20, 0, -120]),
        EQPreset(id: 0x0002, name: "Bass Booster",     values: [40, 30, 10, 0, 0, 0, 0, 0, 0, -120]),
        EQPreset(id: 0x0003, name: "Bass Reducer",     values: [-40, -30, -10, 0, 0, 0, 0, 0, 0, -120]),
        EQPreset(id: 0x0004, name: "Classical",           values: [30, 30, -20, -20, 0, 20, 30, 40, 0, -120]),
        EQPreset(id: 0x0005, name: "Podcast",          values: [-30, 20, 40, 40, 30, 20, 0, -20, 0, -120]),
        EQPreset(id: 0x0006, name: "Dance",             values: [20, -30, -10, 10, 20, 20, 10, -30, 0, -120]),
        EQPreset(id: 0x0007, name: "Deep",            values: [20, 10, 30, 30, 20, -20, -40, -50, 0, -120]),
        EQPreset(id: 0x0008, name: "Electronic",       values: [30, 20, -20, 20, 10, 20, 30, 30, 0, -120]),
        EQPreset(id: 0x0009, name: "Flat",              values: [-20, -20, -10, 0, 0, 0, -20, -20, 0, -120]),
        EQPreset(id: 0x000a, name: "Hip-Hop",          values: [20, 30, -10, -10, 20, -10, 20, 30, 0, -120]),
        EQPreset(id: 0x000b, name: "Jazz",              values: [20, 20, -20, -20, 0, 20, 30, 40, 0, -120]),
        EQPreset(id: 0x000c, name: "Latin",            values: [0, 0, -20, -20, -20, 0, 30, 50, 0, -120]),
        EQPreset(id: 0x000d, name: "Lounge",           values: [-10, 20, 40, 30, 0, -20, 20, 10, 0, -120]),
        EQPreset(id: 0x000e, name: "Piano",           values: [0, 30, 30, 20, 40, 50, 30, 40, 0, -120]),
        EQPreset(id: 0x000f, name: "Pop",              values: [-10, 10, 30, 30, 10, -10, -20, -30, 0, -120]),
        EQPreset(id: 0x0010, name: "R&B",              values: [60, 20, -20, -20, 20, 30, 30, 40, 0, -120]),
        EQPreset(id: 0x0011, name: "Rock",             values: [30, 20, -10, -10, 10, 30, 30, 30, 0, -120]),
        EQPreset(id: 0x0012, name: "Small Speakers",   values: [40, 30, 10, 0, -20, -30, -40, -40, 0, -120]),
        EQPreset(id: 0x0013, name: "Spoken Word",          values: [-30, -20, 10, 20, 20, 10, 0, -30, 0, -120]),
        EQPreset(id: 0x0014, name: "Treble Booster",     values: [-20, -20, -20, -10, 10, 20, 20, 40, 0, -120]),
        EQPreset(id: 0x0015, name: "Treble Reducer",     values: [0, 0, 0, -20, -30, -40, -40, -60, 0, -120]),
    ]

    static func name(for id: UInt16) -> String {
        if id == customProfileID { return "Custom" }
        return presets.first(where: { $0.id == id })?.name ?? String(format: "Profile %02X", id)
    }

    /// dB değerlerini (8 bant) 10 bantlık 0.1 dB tamsayılarına çevirir
    static func tenths(fromDecibels db: [Double]) -> [Int] {
        db.prefix(8).map { Int((min(max($0, range.lowerBound), range.upperBound) * 10).rounded()) } + [0, 0]
    }

    /// EQ ayarlama paketinin gövdesi: profil + sol + sağ + DRC sol + DRC sağ
    static func body(profileID: UInt16, tenths: [Int]) -> [UInt8] {
        let bands = tenths.map { UInt8(clamping: $0 + 120) }
        let drc = applyDRC(tenths).map { UInt8(clamping: $0 + 120) }
        return [UInt8(profileID & 0xFF), UInt8(profileID >> 8)] + bands + bands + drc + drc
    }

    /// DRC eğrisi: EQ bantlarından ses işlemcisinin beklediği telafi değerlerini hesaplar
    static func applyDRC(_ tenths: [Int]) -> [Int] {
        let s = 0.85
        let c: [[Double]] = [
            [1.26, -0.6035, 0.177, -0.0494, 0.0345, -0.0197, 0.0075, -0.00217],
            [-0.6035, 1.6435, 0.0, 0.204, -0.068, 0.045, -0.0235, 0.0075],
            [0.177, -0.6885, 1.6435, -0.6885, 0.208, -0.07, 0.045, -0.0197],
            [-0.0494, 0.204, 0.0, 1.6435, -0.697, 0.208, -0.068, 0.0345],
            [0.0345, -0.068, 0.208, -0.697, 1.6435, 0.0, 0.204, -0.0494],
            [-0.0197, 0.045, -0.07, 0.208, -0.6885, 1.6435, -0.6885, 0.177],
            [0.0075, -0.0235, 0.045, -0.068, 0.204, 0.0, 1.7385, -0.6035],
            [-0.00217, 0.0075, -0.0197, 0.0345, -0.0494, 0.177, -0.6035, 1.5],
        ]
        let a = tenths.prefix(8).map { Double($0) / 10 }
        let lows = a[2] * 0.81 * s
        let highs = a[5] * 0.81 * s
        var out: [Int] = []
        for band in 0..<8 {
            var acc = 0.0
            for i in 0..<8 {
                if (band == 1 || band == 3) && i == 2 {
                    acc -= lows
                } else if (band == 4 || band == 6) && i == 5 {
                    acc -= highs
                } else {
                    acc += a[i] * c[band][i]
                }
            }
            out.append(Int((acc / 10 * 10).rounded()))
        }
        return out + [0, -120]
    }
}
