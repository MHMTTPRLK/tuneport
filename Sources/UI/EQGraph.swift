// SPDX-License-Identifier: GPL-3.0-or-later
// Noktaları sürüklenerek düzenlenen ekolayzır eğrisi

import SwiftUI

struct EQGraph: View {
    @Binding var values: [Double]          // 8 bant, dB
    var onEditingChanged: (Bool) -> Void
    var onCommit: () -> Void

    @State private var activeBand: Int?
    private let range = Equalizer.range
    private let handleSize: CGFloat = 14

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let size = geo.size
                let pts = points(in: size)
                ZStack {
                    // 0 dB çizgisi
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y(0, size.height)))
                        p.addLine(to: CGPoint(x: size.width, y: y(0, size.height)))
                    }
                    .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    // Dolgu
                    curve(pts, width: size.width, closeTo: size.height)
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))

                    // Eğri
                    curve(pts, width: size.width, closeTo: nil)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))

                    // Tutamaklar
                    ForEach(0..<8, id: \.self) { i in
                        Circle()
                            .fill(activeBand == i ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                            .frame(width: handleSize, height: handleSize)
                            .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                            .position(pts[i])
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let band = activeBand ?? nearestBand(to: g.startLocation.x, width: size.width)
                            if activeBand == nil {
                                activeBand = band
                                onEditingChanged(true)
                            }
                            values[band] = value(atY: g.location.y, height: size.height)
                        }
                        .onEnded { _ in
                            activeBand = nil
                            onEditingChanged(false)
                            onCommit()
                        }
                )
            }
            .frame(height: 110)

            // Frekans etiketleri / etkin bandın değeri
            HStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in
                    Text(activeBand == i ? String(format: "%+.1f", values[i]) : Equalizer.bandLabels[i])
                        .font(.system(size: 9, weight: activeBand == i ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(activeBand == i ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Geometri

    private func x(_ i: Int, _ width: CGFloat) -> CGFloat {
        width / 8 * (CGFloat(i) + 0.5)
    }

    private func y(_ v: Double, _ height: CGFloat) -> CGFloat {
        let inset = handleSize / 2 + 2
        let t = (range.upperBound - v) / (range.upperBound - range.lowerBound)
        return inset + CGFloat(t) * (height - inset * 2)
    }

    private func value(atY py: CGFloat, height: CGFloat) -> Double {
        let inset = handleSize / 2 + 2
        let t = Double((py - inset) / (height - inset * 2))
        let v = range.upperBound - t * (range.upperBound - range.lowerBound)
        return (min(max(v, range.lowerBound), range.upperBound) * 2).rounded() / 2
    }

    private func nearestBand(to px: CGFloat, width: CGFloat) -> Int {
        min(max(Int(px / (width / 8)), 0), 7)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        (0..<8).map { i in
            CGPoint(x: x(i, size.width), y: y(i < values.count ? values[i] : 0, size.height))
        }
    }

    /// Noktalardan geçen yumuşak (Catmull-Rom) eğri. closeTo verilirse alt kenara kapatılır.
    private func curve(_ p: [CGPoint], width: CGFloat, closeTo bottom: CGFloat?) -> Path {
        Path { path in
            let first = CGPoint(x: 0, y: p[0].y)
            let last = CGPoint(x: width, y: p[p.count - 1].y)
            let all = [first] + p + [last]
            if let bottom {
                path.move(to: CGPoint(x: 0, y: bottom))
                path.addLine(to: first)
            } else {
                path.move(to: first)
            }
            for i in 0..<(all.count - 1) {
                let p0 = all[max(i - 1, 0)]
                let p1 = all[i]
                let p2 = all[i + 1]
                let p3 = all[min(i + 2, all.count - 1)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
            if let bottom {
                path.addLine(to: CGPoint(x: width, y: bottom))
                path.closeSubpath()
            }
        }
    }
}
