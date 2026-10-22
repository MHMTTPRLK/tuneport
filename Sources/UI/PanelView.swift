// SPDX-License-Identifier: GPL-3.0-or-later
// Menü çubuğu paneli

import SwiftUI

struct PanelView: View {
    @EnvironmentObject var ctl: P3Controller
    @EnvironmentObject var loginItem: LoginItem
    @EnvironmentObject var lang: LanguageManager
    @EnvironmentObject var volume: EarbudVolume
    @EnvironmentObject var translator: LiveTranslator
    @EnvironmentObject var nowPlaying: NowPlaying
    @AppStorage("showBatteryInMenuBar") private var showBatteryInMenuBar = true
    @AppStorage("translateExpanded") private var translateExpanded = false

    var body: some View {
        VStack(spacing: 10) {
            header
            if ctl.isConnected, let s = ctl.state {
                batteryCard(s)
                soundModeCard(s)
                eqCard(s)
                controlsCard(s)
            } else {
                placeholder
            }
            if let info = nowPlaying.info {
                nowPlayingCard(info)
            }
            translateCard
            if ctl.isConnected, let s = ctl.state {
                footer(s)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            ctl.refreshDeviceList()
            volume.attach(toDeviceNamed: ctl.deviceName)
        }
        .onChange(of: ctl.deviceName) { name in volume.attach(toDeviceNamed: name) }
        .onChange(of: ctl.isConnected) { _ in volume.attach(toDeviceNamed: ctl.deviceName) }
    }

    // MARK: Başlık

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15))
                Image(systemName: "earbuds")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                deviceMenu
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            Button { ctl.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(L("Refresh"))

            languageMenu
            settingsMenu
        }
    }

    /// Cihaz adı: tıklanınca Mac'e eşleşmiş Soundcore cihazları listelenir, seçilen cihaza geçilir
    private var deviceMenu: some View {
        Menu {
            if ctl.devices.isEmpty {
                Text(L("No Soundcore earbuds paired"))
            }
            ForEach(ctl.devices) { d in
                Button {
                    ctl.select(d)
                } label: {
                    if d.address == ctl.currentAddress {
                        Label(deviceTitle(d), systemImage: "checkmark")
                    } else {
                        Text(deviceTitle(d))
                    }
                }
            }
            Divider()
            if ctl.devices.contains(where: { $0.address == ctl.currentAddress && $0.isConnected }) {
                Button(L("Disconnect")) { ctl.disconnectCurrent() }
            }
            Button(L("Bluetooth Settings…")) { openBluetoothSettings() }
        } label: {
            HStack(spacing: 3) {
                Text(ctl.deviceName).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Switch earbuds"))
    }

    private func deviceTitle(_ d: P3Controller.KnownDevice) -> String {
        var parts = [d.name]
        if d.isConnected { parts.append(L("Connected")) }
        if !d.isSupported { parts.append(L("audio only")) }
        return parts.joined(separator: " · ")
    }

    private func openBluetoothSettings() {
        let urls = ["x-apple.systempreferences:com.apple.BluetoothSettings",
                    "x-apple.systempreferences:com.apple.preferences.Bluetooth"]
        for u in urls {
            if let url = URL(string: u), NSWorkspace.shared.open(url) { return }
        }
    }

    private var settingsMenu: some View {
        Menu {
            Toggle(L("Launch at login"), isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }))
            Toggle(L("Show battery in menu bar"), isOn: $showBatteryInMenuBar)
            Toggle(L("Use Mac microphone (keeps audio quality high)"), isOn: $ctl.micGuardEnabled)
            Divider()
            Button(L("Quit Tuneport")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Settings"))
    }

    private var languageMenu: some View {
        Menu {
            Picker(L("Language"), selection: $lang.selection) {
                Text(L("System language")).tag(LanguageManager.systemCode)
                Divider()
                ForEach(LanguageManager.available) { language in
                    Text(language.nativeName).tag(language.code)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Language"))
    }

    private var statusText: String {
        switch ctl.connection {
        case .searching: return L("Searching…")
        case .notPaired: return L("No paired earbuds")
        case .disconnected: return L("Not connected")
        case .connecting: return L("Connecting…")
        case .connected: return L("Connected")
        case .unsupported: return L("Connected · audio only")
        case .failed(let msg): return msg
        }
    }

    private var statusColor: Color {
        switch ctl.connection {
        case .connected: return .green
        case .connecting, .searching: return .orange
        default: return .secondary
        }
    }

    // MARK: Bağlı değilken

    private var placeholder: some View {
        Card {
            VStack(spacing: 10) {
                Image(systemName: "earbuds.case")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text(placeholderText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L("Try again")) { ctl.refresh() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var placeholderText: String {
        switch ctl.connection {
        case .notPaired: return L("Pair your earbuds first in System Settings > Bluetooth.")
        case .connecting, .searching: return L("Connecting to your earbuds…")
        case .unsupported: return L("This model isn't supported yet. Audio works normally, but controls are currently available only for the Soundcore Life P3.")
        default: return L("Take your earbuds out of the case. Tuneport connects automatically when they connect to your Mac.")
        }
    }

    // MARK: Pil

    private func batteryCard(_ s: P3State) -> some View {
        Card {
            HStack {
                BatteryGauge(label: L("Left"), level: s.batteryLeft, charging: s.chargingLeft)
                    .help(L("Left earbud"))
                Spacer()
                BatteryGauge(label: L("Right"), level: s.batteryRight, charging: s.chargingRight)
                    .help(L("Right earbud"))
            }
            if volume.isAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(volume.volume) },
                                          set: { volume.setVolume(Float($0)) }),
                           in: 0...1)
                        .controlSize(.small)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .help(L("Earbud volume"))
                .environment(\.layoutDirection, .leftToRight)
            }
        }
    }

    // MARK: Ses modu

    private func soundModeCard(_ s: P3State) -> some View {
        Card(L("Sound mode")) {
            HStack(spacing: 0) {
                ModeButton(title: L("Noise Cancelling"), symbol: "speaker.slash",
                           isSelected: s.ambient == AmbientMode.noiseCanceling.rawValue) {
                    ctl.setAmbient(.noiseCanceling)
                }
                ModeButton(title: L("Normal"), symbol: "ear",
                           isSelected: s.ambient == AmbientMode.normal.rawValue) {
                    ctl.setAmbient(.normal)
                }
                ModeButton(title: L("Transparency"), symbol: "person.wave.2",
                           isSelected: s.ambient == AmbientMode.transparency.rawValue) {
                    ctl.setAmbient(.transparency)
                }
            }

            if s.ambient == AmbientMode.noiseCanceling.rawValue {
                HStack(spacing: 6) {
                    Chip(title: L("Transport"), isSelected: s.noiseCanceling == NoiseCancelingMode.transport.rawValue) {
                        ctl.setNoiseCanceling(.transport)
                    }
                    Chip(title: L("Indoor"), isSelected: s.noiseCanceling == NoiseCancelingMode.indoor.rawValue) {
                        ctl.setNoiseCanceling(.indoor)
                    }
                    Chip(title: L("Outdoor"), isSelected: s.noiseCanceling == NoiseCancelingMode.outdoor.rawValue) {
                        ctl.setNoiseCanceling(.outdoor)
                    }
                }
            } else if s.ambient == AmbientMode.transparency.rawValue {
                HStack(spacing: 6) {
                    Chip(title: L("Full"), isSelected: s.transparency == TransparencyMode.full.rawValue) {
                        ctl.setTransparency(.full)
                    }
                    Chip(title: L("Vocal"), isSelected: s.transparency == TransparencyMode.vocal.rawValue) {
                        ctl.setTransparency(.vocal)
                    }
                }
            }
        }
    }

    // MARK: Şu an çalıyor

    private func nowPlayingCard(_ info: NowPlayingInfo) -> some View {
        Card {
            HStack(spacing: 10) {
                Group {
                    if let art = info.artwork {
                        Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.accentColor.opacity(0.15)
                            Image(systemName: "music.note")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !info.artist.isEmpty {
                        Text(info.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 12) {
                    Button { nowPlaying.previous() } label: { Image(systemName: "backward.fill") }
                        .help(L("Previous track"))
                    Button { nowPlaying.togglePlayPause() } label: {
                        Image(systemName: info.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15))
                    }
                    .help(L("Play / Pause"))
                    Button { nowPlaying.next() } label: { Image(systemName: "forward.fill") }
                        .help(L("Next track"))
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .environment(\.layoutDirection, .leftToRight)
            }
        }
        .help(L("Now playing"))
    }

    // MARK: Canlı çeviri

    private var translateCard: some View {
        Card {
            HStack(spacing: 8) {
                Text(L("Live translation").uppercased(with: lang.locale))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if translator.isRunning {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                }
                Spacer()
                if LiveTranslator.isAvailable {
                    Button {
                        translator.toggle()
                    } label: {
                        Label(translator.isRunning ? L("Stop") : L("Start"),
                              systemImage: translator.isRunning ? "stop.fill" : "captions.bubble")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(translator.isRunning ? .red : .accentColor)
                    .controlSize(.small)
                }
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { translateExpanded.toggle() }
                } label: {
                    Image(systemName: translateExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
            }

            if !LiveTranslator.isAvailable {
                Text(L("Requires macOS 15 or later"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if translateExpanded {
                HStack(spacing: 6) {
                    Chip(title: L("Mac audio"), isSelected: translator.source == .systemAudio) {
                        translator.source = .systemAudio
                    }
                    Chip(title: L("Microphone"), isSelected: translator.source == .microphone) {
                        translator.source = .microphone
                    }
                }
                HStack(spacing: 6) {
                    Picker("", selection: $translator.sourceLanguage) {
                        ForEach(LiveTranslator.sourceLanguages, id: \.self) { code in
                            Text(translator.displayName(forLanguage: code)).tag(code)
                        }
                    }
                    .labelsHidden()
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $translator.targetLanguage) {
                        ForEach(LiveTranslator.targetLanguages, id: \.self) { code in
                            Text(translator.displayName(forLanguage: code)).tag(code)
                        }
                    }
                    .labelsHidden()
                }
                .controlSize(.small)
                .environment(\.layoutDirection, .leftToRight)

                HStack {
                    Toggle(L("Speak translation"), isOn: $translator.speakTranslation)
                    Spacer()
                    Toggle(L("Show original text"), isOn: $translator.showOriginal)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

                if !translator.isRunning && translator.errorMessage == nil {
                    Text(L("Subtitles appear at the bottom of the screen"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if let err = translator.errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if translator.needsLanguageDownload {
                Button {
                    translator.requestLanguageDownload()
                } label: {
                    Label(L("Download languages"), systemImage: "arrow.down.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
            }
        }
        .modifier(LanguageDownloadModifier(translator: translator))
    }

    // MARK: Ekolayzır

    private func eqCard(_ s: P3State) -> some View {
        Card {
            HStack {
                Text(L("Equalizer").uppercased(with: lang.locale))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                presetMenu(current: s.eqProfile)
            }
            EQGraph(values: $ctl.eqDraft,
                    onEditingChanged: { ctl.isEditingEQ = $0 },
                    onCommit: { ctl.applyDraftEQ() })
                .environment(\.layoutDirection, .leftToRight)  // frekans ekseni her dilde soldan sağa
        }
    }

    private func presetMenu(current: UInt16) -> some View {
        Menu {
            ForEach(Equalizer.presets) { p in
                Button {
                    ctl.applyPreset(p)
                } label: {
                    if p.id == current {
                        Label(L(p.name), systemImage: "checkmark")
                    } else {
                        Text(L(p.name))
                    }
                }
            }
            Divider()
            Button(L("My saved custom EQ")) { ctl.applySavedCustomEQ() }
                .disabled(ctl.savedCustomEQ == nil)
            Button(L("Save this curve as my custom EQ")) { ctl.saveCurrentAsCustom() }
            Button(L("Reset (all 0 dB)")) { ctl.resetEQ() }
        } label: {
            Text(L(Equalizer.name(for: current)))
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Dokunmatik kontroller

    private static let buttonNames = ["Left · double tap", "Left · long press", "Right · double tap",
                                      "Right · long press", "Left · single tap", "Right · single tap"]
    private static let actionNames: [UInt8: String] = [
        0: "Volume up", 1: "Volume down", 2: "Previous track", 3: "Next track",
        4: "Switch sound mode", 5: "Voice assistant", 6: "Play / Pause"]

    private func controlsCard(_ s: P3State) -> some View {
        Card {
            DisclosureGroup {
                VStack(spacing: 5) {
                    ForEach(0..<min(6, s.buttons.count), id: \.self) { i in
                        HStack {
                            Text(L(PanelView.buttonNames[i])).font(.system(size: 11))
                            Spacer()
                            Text(actionText(s.buttons[i], single: i >= 4))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(L("Touch controls").uppercased(with: lang.locale))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actionText(_ b: ButtonSlot, single: Bool) -> String {
        guard (b.enabled & 0x0F) == 1 else { return L("Off") }
        let action = single ? b.action : (b.action & 0x0F)
        return L(PanelView.actionNames[action] ?? "?")
    }

    // MARK: Alt bilgi

    private func footer(_ s: P3State) -> some View {
        HStack {
            Text(String(format: L("Firmware %@"), s.firmwareLeft))
            Spacer()
            Text(verbatim: "Tuneport " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }
}
