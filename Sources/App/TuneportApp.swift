// SPDX-License-Identifier: GPL-3.0-or-later
// Tuneport — Soundcore kulaklıklar için macOS menü çubuğu uygulaması

import SwiftUI
import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Terminal'den çalıştırıldığında da Dock'ta görünmesin
        NSApp.setActivationPolicy(.accessory)
    }
}

/// "Girişte otomatik başlat" ayarı (macOS 13+ SMAppService)
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    func setEnabled(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Tuneport: giriş öğesi ayarlanamadı: \(error.localizedDescription)")
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

struct MenuBarLabel: View {
    @ObservedObject var ctl: P3Controller
    @ObservedObject var lang = LanguageManager.shared
    let showBattery: Bool

    var body: some View {
        if showBattery, ctl.isConnected, let s = ctl.state {
            HStack(spacing: 3) {
                Image(systemName: "earbuds")
                Text(percentText(s.lowestBatteryPercent))
            }
        } else {
            Image(systemName: "earbuds")
        }
    }
}

@main
struct TuneportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var ctl = P3Controller()
    @StateObject private var loginItem = LoginItem()
    @StateObject private var volume = EarbudVolume()
    @ObservedObject private var lang = LanguageManager.shared
    @AppStorage("showBatteryInMenuBar") private var showBatteryInMenuBar = true

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(ctl)
                .environmentObject(loginItem)
                .environmentObject(lang)
                .environmentObject(volume)
                .environment(\.locale, lang.locale)
                .environment(\.layoutDirection, lang.isRightToLeft ? .rightToLeft : .leftToRight)
                .id(lang.activeCode)   // dil değişince panel anında yeniden çizilir
        } label: {
            MenuBarLabel(ctl: ctl, showBattery: showBatteryInMenuBar)
        }
        .menuBarExtraStyle(.window)
    }
}
