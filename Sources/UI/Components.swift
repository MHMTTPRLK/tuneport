// SPDX-License-Identifier: GPL-3.0-or-later
// Panelde kullanılan küçük görsel parçalar

import SwiftUI

/// Kontrol Merkezi tarzı yuvarlak mod düğmesi
struct ModeButton: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.08))
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .frame(width: 46, height: 46)
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

/// Küçük hap şeklinde seçenek düğmesi
struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Tek kulaklık için pil göstergesi
struct BatteryGauge: View {
    let label: String
    let level: Int        // 0–5
    let charging: Bool

    private var percent: Int { min(max(level, 0), 5) * 20 }
    private var tint: Color {
        if charging { return .green }
        if percent <= 20 { return .red }
        if percent <= 40 { return .orange }
        return .primary
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                GeometryReader { g in
                    Capsule()
                        .fill(tint.opacity(charging || percent <= 40 ? 1 : 0.75))
                        .frame(width: max(g.size.width * CGFloat(percent) / 100, 4))
                }
            }
            .frame(width: 44, height: 6)
            HStack(spacing: 2) {
                if charging {
                    Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.green)
                }
                Text(percentText(percent))
                    .font(.system(size: 11).monospacedDigit())
            }
        }
    }
}

/// Bölüm kartı
struct Card<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}
