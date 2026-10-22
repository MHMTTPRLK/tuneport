// SPDX-License-Identifier: GPL-3.0-or-later
// Protokol katmanı testleri. Kulaklık gerekmez.
// Çalıştırma: ./build.sh test

import Foundation

// MARK: - Mini test altyapısı

var passed = 0
var failed = 0

func test(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passed += 1
        print("  ✓ \(name)")
    } catch {
        failed += 1
        print("  ✗ \(name)\n      \(error)")
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String = "",
                          line: Int = #line) throws {
    if actual != expected {
        throw Failure(description: "satır \(line) \(what): beklenen \(expected), gelen \(actual)")
    }
}

func hex(_ s: String) -> [UInt8] {
    s.split(separator: " ").map { UInt8($0, radix: 16)! }
}

// MARK: - Test verisi

/// Life P3'ten (firmware 12.14) yakalanmış gerçek durum paketi. Seri numarası anonimleştirildi.
let realStatePacket: [UInt8] = [
    0x09, 0xFF, 0x00, 0x00, 0x01, 0x01, 0x01, 0x8E, 0x00, 0x01, 0x01, 0x04, 0x04, 0x00, 0x00, 0x31,
    0x32, 0x2E, 0x31, 0x34, 0x31, 0x32, 0x2E, 0x31, 0x34, 0x33, 0x39, 0x33, 0x39, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0xFE, 0xFE, 0x79, 0x8F, 0xA1, 0xB1, 0xA2,
    0xB1, 0xA1, 0x7F, 0x78, 0x78, 0x79, 0x8F, 0xA1, 0xB1, 0xA2, 0xB1, 0xA1, 0x7F, 0x78, 0x78, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0x01, 0x63, 0x01, 0x54, 0x01, 0x66, 0x01, 0x54, 0x00, 0x01, 0x00, 0x00, 0x05, 0x02, 0x01, 0x00,
    0x00, 0xFF, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0xFF, 0x31, 0x11, 0x11, 0x11, 0x11, 0xDA,
]

func parseRealState() throws -> P3State {
    var parser = FrameParser()
    let frames = parser.feed(realStatePacket)
    try expect(frames.count, 1, "paket sayısı")
    guard let state = P3State(frames[0].1) else { throw Failure(description: "durum çözülemedi") }
    return state
}

// MARK: - Testler

print("\nPaket")

test("durum isteği paketi") {
    try expect(Packet.build(.requestState), hex("08 EE 00 00 00 01 01 0A 00 02"))
}

test("ses modu paketi: Normal") {
    try expect(Packet.build(.setSoundModes, [0x02, 0x00, 0x01, 0x00]),
               hex("08 EE 00 00 00 06 81 0E 00 02 00 01 00 8E"))
}

test("ses modu paketi: ANC dış mekan") {
    try expect(Packet.build(.setSoundModes, [0x00, 0x01, 0x01, 0x00]),
               hex("08 EE 00 00 00 06 81 0E 00 00 01 01 00 8D"))
}

test("checksum taşması 256'da sarılır") {
    try expect(Packet.checksum([0xFF, 0x02]), 0x01)
}

print("\nAyrıştırıcı")

test("tek parça gelen paket") {
    var p = FrameParser()
    let frames = p.feed(realStatePacket)
    try expect(frames.count, 1)
    try expect(frames[0].0, Command.requestState)
    try expect(frames[0].1.count, 142 - 10)
}

test("parça parça gelen paket") {
    var p = FrameParser()
    var frames: [(Command, [UInt8])] = []
    for chunk in stride(from: 0, to: realStatePacket.count, by: 7) {
        let end = min(chunk + 7, realStatePacket.count)
        frames += p.feed(Array(realStatePacket[chunk..<end]))
    }
    try expect(frames.count, 1)
}

test("öncesinde çöp byte olan akış") {
    var p = FrameParser()
    let frames = p.feed([0x00, 0x13, 0x37] + realStatePacket)
    try expect(frames.count, 1)
}

test("bozuk checksum'lı paket atlanır") {
    var bad = realStatePacket
    bad[bad.count - 1] &+= 1
    var p = FrameParser()
    try expect(p.feed(bad).count, 0)
}

test("art arda iki paket (onay + durum)") {
    var p = FrameParser()
    let ack = hex("09 FF 00 00 01 02 83 0A 00 98")
    let frames = p.feed(ack + realStatePacket)
    try expect(frames.count, 2)
    try expect(frames[0].0, Command.setEQWithDRC)
    try expect(frames[1].0, Command.requestState)
}

print("\nDurum")

test("pil ve şarj") {
    let s = try parseRealState()
    try expect(s.batteryLeft, 4); try expect(s.batteryRight, 4)
    try expect(s.chargingLeft, false); try expect(s.chargingRight, false)
    try expect(s.lowestBatteryPercent, 80)
}

test("firmware ve seri numarası") {
    let s = try parseRealState()
    try expect(s.firmwareLeft, "12.14"); try expect(s.firmwareRight, "12.14")
    try expect(s.serial, "3939000000000000")
}

test("ses modu") {
    let s = try parseRealState()
    try expect(s.ambient, AmbientMode.normal.rawValue)
    try expect(s.noiseCanceling, NoiseCancelingMode.outdoor.rawValue)
    try expect(s.transparency, TransparencyMode.full.rawValue)
    try expect(s.modeCycle, 0x05, "döngü: ANC + Normal")
}

test("özel EQ değerleri") {
    let s = try parseRealState()
    try expect(s.eqProfile, Equalizer.customProfileID)
    try expect(s.eqDecibels.map { Int(($0 * 10).rounded()) }, [1, 23, 41, 57, 42, 57, 41, 7])
}

test("dokunmatik tuşlar") {
    let s = try parseRealState()
    try expect(s.buttons.count, 6)
    try expect(s.buttons[0].action & 0x0F, 3, "sol çift = sonraki parça")
    try expect(s.buttons[2].action & 0x0F, 6, "sağ çift = oynat/duraklat")
    try expect(s.buttons[4].enabled, 0, "sol tek kapalı")
}

test("ek ayarlar") {
    let s = try parseRealState()
    try expect(s.touchTone, 0)
    try expect(s.gamingMode, 0)
}

test("kısa gövde reddedilir") {
    try expect(P3State(Array(repeating: 0, count: 50)) == nil, true)
}

print("\nEkolayzır")

test("DRC referans vektörü") {
    let drc = Equalizer.applyDRC([-60, 60, 23, 120, 22, -120, -4, 16, 0, 0])
    try expect(Array(drc.prefix(8)).map { UInt8($0 + 120) }, hex("6D 86 70 88 7B 66 7E 79"))
    try expect(Array(drc.suffix(2)), [0, -120])
}

test("kulaklığın kabul ettiği gerçek EQ paketi") {
    // Bas +10, tiz -10: Life P3 bu paketi onayladı ve ses duyulur şekilde değişti
    let tenths = Equalizer.tenths(fromDecibels: [10, 10, 0, 0, -10, -10, -10, -10])
    let pkt = Packet.build(.setEQWithDRC, Equalizer.body(profileID: Equalizer.customProfileID, tenths: tenths))
    try expect(pkt, hex("""
        08 EE 00 00 00 02 83 34 00 FE FE DC DC 78 78 14 14 14 14 78 78 DC DC 78 78 14 14 14 14 78 78 \
        7E 83 71 7F 6D 74 71 6E 78 00 7E 83 71 7F 6D 74 71 6E 78 00 CD
        """))
}

test("dB değerleri sınırlandırılır ve yuvarlanır") {
    try expect(Equalizer.tenths(fromDecibels: [20, -20, 0.04, 2.25, 0, 0, 0, 0]),
               [135, -120, 0, 23, 0, 0, 0, 0, 0, 0])
}

test("22 hazır profil, benzersiz ID'ler") {
    try expect(Equalizer.presets.count, 22)
    try expect(Set(Equalizer.presets.map(\.id)).count, 22)
    try expect(Equalizer.presets.allSatisfy { $0.values.count == 10 }, true)
}

test("profil adları") {
    try expect(Equalizer.name(for: 0xFEFE), "Custom")
    try expect(Equalizer.name(for: 0x0002), "Bass Booster")
}

// MARK: - Sonuç

print("\n\(passed) başarılı, \(failed) başarısız\n")
exit(failed == 0 ? 0 : 1)
