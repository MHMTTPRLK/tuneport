// SPDX-License-Identifier: GPL-3.0-or-later
// p3ctl — Tuneport'un geliştirme/teşhis aracı: Life P3'ü komut satırından okur ve kontrol eder.
// Tuneport açıkken kullanma; kontrol kanalını aynı anda tek program kullanabilir.
//
// Derleme:  swiftc Tools/p3ctl.swift -framework IOBluetooth -o build/p3ctl
// Kullanım:
//   ~/p3ctl                      -> durum
//   ~/p3ctl mod anc|seffaf|normal
//   ~/p3ctl anc ulasim|dis|ic    -> gürültü engelleme türü
//   ~/p3ctl seffaf tam|ses       -> şeffaf mod türü
//   ~/p3ctl eq d1 d2 ... d8      -> 8 bant EQ, dB (-12.0 ... +13.5)
//   ~/p3ctl eq duz               -> EQ sıfırla
//   ~/p3ctl ham                  -> ham durum paketini hex olarak yazdır

import Foundation
import IOBluetooth

let CONTROL_CHANNEL: BluetoothRFCOMMChannelID = 5

// MARK: - Paket katmanı

func checksum(_ bytes: [UInt8]) -> UInt8 {
    bytes.reduce(0) { $0 &+ $1 }
}

func buildPacket(_ cmd: (UInt8, UInt8), _ body: [UInt8]) -> [UInt8] {
    let total = 5 + 2 + 2 + body.count + 1
    var p: [UInt8] = [0x08, 0xEE, 0x00, 0x00, 0x00, cmd.0, cmd.1,
                      UInt8(total & 0xFF), UInt8(total >> 8)]
    p += body
    p.append(checksum(p))
    return p
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }


// MARK: - DRC (bazı Soundcore modellerinin EQ'yu ses işlemcisine uygulamak için istediği ek eğri)

func applyDRC(_ tenths: [Int]) -> [Int] {
    let S = 0.85
    let C: [[Double]] = [
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
    let lo = a[2] * 0.81 * S, hi = a[5] * 0.81 * S
    var out: [Int] = []
    for bi in 0..<8 {
        var acc = 0.0
        for i in 0..<8 {
            if (bi == 1 || bi == 3) && i == 2 { acc -= lo }
            else if (bi == 4 || bi == 6) && i == 5 { acc -= hi }
            else { acc += a[i] * C[bi][i] }
        }
        out.append(Int((acc / 10 * 10).rounded()))
    }
    return out + [0, -120]
}

// MARK: - Bağlantı

var DEBUG = CommandLine.arguments.contains("-v")

final class Connection: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private var buffer: [UInt8] = []
    var rawLog: [UInt8] = []
    private var channel: IOBluetoothRFCOMMChannel?

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let p = dataPointer.assumingMemoryBound(to: UInt8.self)
        let chunk = Array(UnsafeBufferPointer(start: p, count: dataLength))
        buffer += chunk
        rawLog += chunk
    }

    func open() -> Bool {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice],
              let dev = devices.first(where: { ($0.name ?? "").lowercased().contains("p3") }) else {
            print("❌ Soundcore P3 eşleşmiş cihazlarda bulunamadı."); return false
        }
        guard dev.isConnected() else {
            print("❌ \(dev.name ?? "Kulaklık") bağlı değil. Önce Mac'e bağla."); return false
        }
        var ch: IOBluetoothRFCOMMChannel? = nil
        let r = dev.openRFCOMMChannelSync(&ch, withChannelID: CONTROL_CHANNEL, delegate: self)
        guard r == kIOReturnSuccess, let c = ch else {
            print("❌ Kontrol kanalı açılamadı (kod \(r))."); return false
        }
        channel = c
        return true
    }

    func close() {
        channel?.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    func send(_ cmd: (UInt8, UInt8), _ body: [UInt8] = []) {
        var pkt = buildPacket(cmd, body)
        if DEBUG { print("→ GÖNDERİLEN: \(hex(pkt))") }
        let r = pkt.withUnsafeMutableBytes { channel!.writeSync($0.baseAddress, length: UInt16($0.count)) }
        if r != kIOReturnSuccess { print("⚠️  Yazma hatası (\(r))") }
    }

    /// Belirtilen komuta ait gelen paketi bekler; bulursa gövdesini döndürür.
    func wait(for cmd: (UInt8, UInt8), timeout: TimeInterval = 3) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let body = extract(cmd) { return body }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return extract(cmd)
    }

    private func extract(_ cmd: (UInt8, UInt8)) -> [UInt8]? {
        while buffer.count >= 10 {
            guard let start = findHeader() else { buffer.removeAll(); return nil }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 9 else { return nil }
            let len = Int(buffer[7]) | (Int(buffer[8]) << 8)
            guard len >= 10, buffer.count >= len else { return nil }
            let frame = Array(buffer[0..<len])
            buffer.removeFirst(len)
            guard checksum(Array(frame.dropLast())) == frame.last! else { continue }
            if frame[5] == cmd.0 && frame[6] == cmd.1 { return Array(frame[9..<(len - 1)]) }
        }
        return nil
    }

    private func findHeader() -> Int? {
        let h: [UInt8] = [0x09, 0xFF, 0x00, 0x00, 0x01]
        guard buffer.count >= h.count else { return nil }
        for i in 0...(buffer.count - h.count) where Array(buffer[i..<(i + h.count)]) == h { return i }
        return nil
    }
}

// MARK: - Durum

struct State {
    var raw: [UInt8]
    var batteryL: Int, batteryR: Int, chargingL: Bool, chargingR: Bool
    var fwL: String, fwR: String, serial: String
    var eqProfile: UInt16, eqL: [UInt8], eqR: [UInt8]
    var buttons: [(enabled: UInt8, action: UInt8)]
    var cycle: UInt8
    var ambient: UInt8, ncMode: UInt8, transMode: UInt8, customNC: UInt8

    init?(_ b: [UInt8]) {
        guard b.count >= 125 else { return nil }
        var i = 0
        func take(_ n: Int) -> [UInt8] { defer { i += n }; return Array(b[i..<(i + n)]) }
        raw = b
        _ = take(2) // host cihaz + tws durumu
        let bat = take(4)
        batteryL = Int(bat[0]); batteryR = Int(bat[1]); chargingL = bat[2] != 0; chargingR = bat[3] != 0
        let fw = take(10)
        fwL = String(bytes: fw[0..<5], encoding: .ascii) ?? "?"
        fwR = String(bytes: fw[5..<10], encoding: .ascii) ?? "?"
        serial = String(bytes: take(16), encoding: .ascii) ?? "?"
        let pid = take(2); eqProfile = UInt16(pid[0]) | (UInt16(pid[1]) << 8)
        eqL = take(10); eqR = take(10)
        _ = take(1)   // yaş aralığı
        _ = take(48)  // HearID
        var btns: [(enabled: UInt8, action: UInt8)] = []
        for _ in 0..<6 { let x = take(2); btns.append((x[0], x[1])) }
        buttons = btns
        cycle = take(1)[0]
        let m = take(4)
        ambient = m[0]; ncMode = m[1]; transMode = m[2]; customNC = m[3]
    }
}

let ambientNames: [UInt8: String] = [0: "Gürültü Engelleme (ANC)", 1: "Şeffaf", 2: "Normal"]
let ncNames: [UInt8: String] = [0: "Ulaşım", 1: "Dış mekan", 2: "İç mekan", 3: "Özel"]
let transNames: [UInt8: String] = [0: "Tam şeffaf", 1: "Ses odaklı"]
let actionNames: [UInt8: String] = [0: "Ses +", 1: "Ses −", 2: "Önceki şarkı", 3: "Sonraki şarkı",
                                    4: "Mod değiştir (ANC/Şeffaf)", 5: "Sesli asistan", 6: "Oynat/Duraklat"]
let buttonNames = ["Sol çift dokunma", "Sol uzun basma", "Sağ çift dokunma",
                   "Sağ uzun basma", "Sol tek dokunma", "Sağ tek dokunma"]
let bands = ["100Hz", "200Hz", "400Hz", "800Hz", "1.6k", "3.2k", "6.4k", "12.8k"]

func dB(_ v: UInt8) -> String { String(format: "%+.1f", (Double(v) - 120) / 10) }

func printState(_ s: State) {
    func bat(_ l: Int, _ c: Bool) -> String { "%\(min(l, 5) * 20)" + (c ? " ⚡" : "") }
    print("🎧 Soundcore Life P3  (firmware \(s.fwL) / \(s.fwR))")
    print("🔋 Pil:   Sol \(bat(s.batteryL, s.chargingL))   Sağ \(bat(s.batteryR, s.chargingR))")
    print("🔊 Mod:   \(ambientNames[s.ambient] ?? "?(\(s.ambient))")")
    print("   ANC türü: \(ncNames[s.ncMode] ?? "?")   Şeffaf türü: \(transNames[s.transMode] ?? "?")")
    let eqName = s.eqProfile == 0xFEFE ? "Özel" : String(format: "Hazır profil #%04X", s.eqProfile)
    print("🎚  EQ (\(eqName)):")
    print("   " + zip(bands, s.eqL.prefix(8)).map { "\($0) \(dB($1))" }.joined(separator: "  "))
    print("👆 Tuşlar:")
    for (n, b) in zip(buttonNames, s.buttons) {
        let connected = b.action & 0x0F
        let action = n.contains("tek") ? b.action : connected
        let on = (b.enabled & 0x0F) == 1
        print("   \(n.padding(toLength: 17, withPad: " ", startingAt: 0)) \(on ? (actionNames[action] ?? "?(\(action))") : "kapalı")")
    }
}

// MARK: - Ana akış

let args = Array(CommandLine.arguments.dropFirst()).filter { $0 != "-v" }
let conn = Connection()
guard conn.open() else { exit(1) }
defer { conn.close() }

func readState() -> State? {
    conn.send((0x01, 0x01))
    guard let body = conn.wait(for: (0x01, 0x01)), let s = State(body) else {
        print("❌ Durum okunamadı."); return nil
    }
    return s
}

func setSoundModes(_ s: State, ambient: UInt8? = nil, nc: UInt8? = nil, trans: UInt8? = nil) {
    conn.send((0x06, 0x81), [ambient ?? s.ambient, nc ?? s.ncMode, trans ?? s.transMode, s.customNC])
}

guard let state = readState() else { exit(1) }
let cmd = args.first?.lowercased() ?? "durum"
var changed = true

let sendMark = conn.rawLog.count
switch cmd {
case "durum":
    changed = false
case "ham":
    print(hex(state.raw)); changed = false
case "mod":
    let map: [String: UInt8] = ["anc": 0, "seffaf": 1, "şeffaf": 1, "normal": 2]
    guard args.count > 1, let v = map[args[1].lowercased()] else { print("Kullanım: p3ctl mod anc|seffaf|normal"); exit(1) }
    setSoundModes(state, ambient: v)
case "anc":
    let map: [String: UInt8] = ["ulasim": 0, "dis": 1, "ic": 2]
    guard args.count > 1, let v = map[args[1].lowercased()] else { print("Kullanım: p3ctl anc ulasim|dis|ic"); exit(1) }
    setSoundModes(state, ambient: 0, nc: v)
case "seffaf", "şeffaf":
    let map: [String: UInt8] = ["tam": 0, "ses": 1]
    guard args.count > 1, let v = map[args[1].lowercased()] else { print("Kullanım: p3ctl seffaf tam|ses"); exit(1) }
    setSoundModes(state, ambient: 1, trans: v)
case "eq":
    var values: [UInt8]
    if args.count == 2 && args[1].lowercased() == "duz" {
        values = Array(repeating: 120, count: 8)
    } else {
        let nums = args.dropFirst().compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard nums.count == 8, nums.allSatisfy({ $0 >= -12 && $0 <= 13.5 }) else {
            print("Kullanım: p3ctl eq d1 d2 d3 d4 d5 d6 d7 d8   (her biri -12 ile +13.5 dB arası)")
            print("          p3ctl eq duz")
            exit(1)
        }
        values = nums.map { UInt8(($0 * 10).rounded() + 120) }
    }
    let left = values + Array(state.eqL.suffix(2))
    let right = values + Array(state.eqR.suffix(2))
    conn.send((0x02, 0x81), [0xFE, 0xFE] + left + right)
case "eqdrc":
    // Aynı EQ, DRC'li komutla (02 83) gönderilir
    let nums = args.dropFirst().compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
    guard nums.count == 8, nums.allSatisfy({ $0 >= -12 && $0 <= 13.5 }) else {
        print("Kullanım: p3ctl eqdrc d1 d2 d3 d4 d5 d6 d7 d8"); exit(1)
    }
    let tenths = nums.map { Int(($0 * 10).rounded()) } + [0, 0]
    let eqBytes = tenths.map { UInt8(clamping: $0 + 120) }
    let drcBytes = applyDRC(tenths).map { UInt8(clamping: $0 + 120) }
    conn.send((0x02, 0x83), [0xFE, 0xFE] + eqBytes + eqBytes + drcBytes + drcBytes)
default:
    print("Bilinmeyen komut: \(cmd)")
    print("Komutlar: durum | mod <anc|seffaf|normal> | anc <ulasim|dis|ic> | seffaf <tam|ses> | eq <8 değer>|duz | ham")
    exit(1)
}

if changed {
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    if DEBUG {
        let got = Array(conn.rawLog[sendMark...])
        print("← KULAKLIKTAN GELEN (\(got.count) byte): " + (got.isEmpty ? "hiçbir şey" : hex(got)))
        print("")
    }
    print("✅ Komut gönderildi. Yeni durum:\n")
    guard let s2 = readState() else { exit(1) }
    printState(s2)
} else if cmd == "durum" {
    printState(state)
}
