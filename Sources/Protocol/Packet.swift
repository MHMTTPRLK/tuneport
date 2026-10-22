// SPDX-License-Identifier: GPL-3.0-or-later
// Soundcore paket formatı
// Giden:  08 EE 00 00 00 | komut(2) | toplam uzunluk(2, LE) | gövde | checksum
// Gelen:  09 FF 00 00 01 | komut(2) | toplam uzunluk(2, LE) | gövde | checksum
// checksum = önceki tüm byte'ların toplamı (mod 256)

import Foundation

struct Command: Equatable, Hashable {
    let a: UInt8
    let b: UInt8
    init(_ a: UInt8, _ b: UInt8) { self.a = a; self.b = b }

    static let requestState  = Command(0x01, 0x01)
    static let setSoundModes = Command(0x06, 0x81)
    static let setModeCycle  = Command(0x06, 0x82)
    static let setEQWithDRC  = Command(0x02, 0x83)
}

enum Packet {
    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }

    static func build(_ cmd: Command, _ body: [UInt8] = []) -> [UInt8] {
        let total = 5 + 2 + 2 + body.count + 1
        var p: [UInt8] = [0x08, 0xEE, 0x00, 0x00, 0x00, cmd.a, cmd.b,
                          UInt8(total & 0xFF), UInt8(total >> 8)]
        p += body
        p.append(checksum(p))
        return p
    }
}

/// Gelen byte akışını paketlere ayırır (paketler parça parça gelebilir).
struct FrameParser {
    private var buffer: [UInt8] = []
    private static let header: [UInt8] = [0x09, 0xFF, 0x00, 0x00, 0x01]

    mutating func feed(_ bytes: [UInt8]) -> [(Command, [UInt8])] {
        buffer += bytes
        var frames: [(Command, [UInt8])] = []
        while buffer.count >= 10 {
            guard let start = findHeader() else {
                // Başlık yok: son 4 byte bir sonraki başlığın başı olabilir, sakla
                buffer = Array(buffer.suffix(4))
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 9 else { break }
            let len = Int(buffer[7]) | (Int(buffer[8]) << 8)
            guard len >= 10 else { buffer.removeFirst(5); continue }
            guard buffer.count >= len else { break }
            let frame = Array(buffer[0..<len])
            buffer.removeFirst(len)
            guard Packet.checksum(Array(frame.dropLast())) == frame[len - 1] else { continue }
            frames.append((Command(frame[5], frame[6]), Array(frame[9..<(len - 1)])))
        }
        return frames
    }

    private func findHeader() -> Int? {
        let h = FrameParser.header
        guard buffer.count >= h.count else { return nil }
        for i in 0...(buffer.count - h.count) where Array(buffer[i..<(i + h.count)]) == h {
            return i
        }
        return nil
    }
}
