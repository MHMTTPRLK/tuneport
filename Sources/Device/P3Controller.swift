// SPDX-License-Identifier: GPL-3.0-or-later
// Kulaklıkla RFCOMM üzerinden konuşan ve arayüze durum yayınlayan kontrolcü

import Foundation
import AppKit
import IOBluetooth

final class P3Controller: NSObject, ObservableObject, IOBluetoothRFCOMMChannelDelegate {
    enum ConnectionState: Equatable {
        case searching, notPaired, disconnected, connecting, connected, unsupported, failed(String)
    }

    /// Mac'e eşleşmiş bir Soundcore cihazı
    struct KnownDevice: Identifiable, Hashable {
        let address: String
        let name: String
        let isConnected: Bool
        let isSupported: Bool
        var id: String { address }
    }

    static let controlChannel: BluetoothRFCOMMChannelID = 5

    @Published private(set) var connection: ConnectionState = .searching
    @Published private(set) var state: P3State?
    @Published private(set) var deviceName = "Soundcore"
    @Published private(set) var devices: [KnownDevice] = []
    @Published private(set) var selectedAddress: String? = UserDefaults.standard.string(forKey: "selectedDevice")
    @Published var eqDraft: [Double] = Array(repeating: 0, count: 8)
    @Published var micGuardEnabled: Bool {
        didSet {
            UserDefaults.standard.set(micGuardEnabled, forKey: "micGuardEnabled")
            micGuard.isEnabled = micGuardEnabled
        }
    }

    var isEditingEQ = false
    private let micGuard: AudioInputGuard
    private var channel: IOBluetoothRFCOMMChannel?
    private var parser = FrameParser()
    private var timer: Timer?
    private var refreshPending = false
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?
    private var connectAttempts = 0
    /// Kanal açma isteği gönderildi, sonucu bekleniyor
    private var isOpening = false

    override init() {
        let micDefault = UserDefaults.standard.object(forKey: "micGuardEnabled") as? Bool ?? true
        micGuardEnabled = micDefault
        micGuard = AudioInputGuard(enabled: micDefault)
        super.init()

        // Kulaklık Mac'e bağlandığı an haberdar ol
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:)))

        // Uygulama kapanırken kanalı düzgünce kapat; kulaklıkta yarım bağlantı kalmasın
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.closeControlChannel()
        }

        connect()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshDeviceList()
            if self.connection == .connected { self.requestState() } else { self.connect() }
        }
    }

    // MARK: Bağlantı

    var isConnected: Bool { connection == .connected }

    var savedCustomEQ: [Int]? {
        get { UserDefaults.standard.array(forKey: "savedCustomEQ") as? [Int] }
        set { UserDefaults.standard.set(newValue, forKey: "savedCustomEQ") }
    }

    // MARK: Cihaz listesi ve geçiş

    /// Şimdilik kontrolleri desteklenen model: Life P3 (A3939)
    static func isSupported(_ d: IOBluetoothDevice) -> Bool {
        (d.name ?? "").lowercased().contains("p3")
    }

    static func isSoundcore(_ d: IOBluetoothDevice) -> Bool {
        (d.name ?? "").lowercased().contains("soundcore") || isSupported(d)
    }

    private func soundcoreDevices() -> [IOBluetoothDevice] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return paired.filter(P3Controller.isSoundcore)
    }

    func refreshDeviceList() {
        devices = soundcoreDevices().map {
            KnownDevice(address: $0.addressString ?? "", name: $0.name ?? "Soundcore",
                        isConnected: $0.isConnected(), isSupported: P3Controller.isSupported($0))
        }
    }

    /// Kontrol edilecek cihaz: kullanıcının seçtiği, yoksa bağlı ve desteklenen ilk cihaz
    private func targetDevice() -> IOBluetoothDevice? {
        let all = soundcoreDevices()
        if let addr = selectedAddress, let d = all.first(where: { $0.addressString == addr }) { return d }
        return all.first { $0.isConnected() && P3Controller.isSupported($0) }
            ?? all.first { $0.isConnected() }
            ?? all.first(where: P3Controller.isSupported)
            ?? all.first
    }

    var currentAddress: String? { targetDevice()?.addressString }

    /// Başka bir Soundcore cihazına geç: mevcut bağlantıyı bırak, seçileni bağla
    func select(_ device: KnownDevice) {
        guard let target = IOBluetoothDevice(addressString: device.address) else { return }
        closeControlChannel()
        for d in soundcoreDevices() where d.isConnected() && d.addressString != device.address {
            d.closeConnection()
        }
        selectedAddress = device.address
        UserDefaults.standard.set(device.address, forKey: "selectedDevice")
        state = nil
        deviceName = device.name
        connection = .connecting
        if target.isConnected() {
            connect()
        } else {
            let r = target.openConnection(self)   // sonuç connectionComplete(_:status:) ile gelir
            if r != kIOReturnSuccess {
                connection = .failed(String(format: L("Could not connect (%d)"), Int(r)))
            }
        }
        refreshDeviceList()
    }

    /// Seçili kulaklığın Bluetooth bağlantısını kes
    func disconnectCurrent() {
        guard let d = targetDevice() else { return }
        closeControlChannel()
        d.closeConnection()
        state = nil
        connection = .disconnected
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshDeviceList() }
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        if status == kIOReturnSuccess {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.refreshDeviceList()
                self?.connect()
                self?.micGuard.enforce()
            }
        } else {
            connection = .failed(String(format: L("Could not connect (%d)"), Int(status)))
            refreshDeviceList()
        }
    }

    private func closeControlChannel() {
        let old = channel
        channel = nil
        isOpening = false          // eski kanalın geç gelen bildirimleri yok sayılsın
        parser = FrameParser()
        old?.close()
    }

    // MARK: Kontrol kanalı

    func connect() {
        guard channel == nil else { return }
        refreshDeviceList()
        guard let device = targetDevice() else { NSLog("Tuneport: eşleşmiş Soundcore cihazı yok"); connection = .notPaired; return }
        deviceName = device.name ?? deviceName
        NSLog("Tuneport: hedef %@ [%@], bağlı: %@", device.name ?? "?", device.addressString ?? "?", device.isConnected() ? "evet" : "hayır")
        guard device.isConnected() else { connection = .disconnected; return }
        guard P3Controller.isSupported(device) else { state = nil; connection = .unsupported; return }
        var ch: IOBluetoothRFCOMMChannel? = nil
        NSLog("Tuneport: kanal açılıyor → %@ (deneme %d)", device.name ?? "?", connectAttempts + 1)
        isOpening = true
        connection = .connecting
        // Not: kanal hızlı açılırsa macOS "açıldı" bildirimini bu çağrı dönmeden gönderebilir;
        // o yüzden bildirim, isOpening sırasında henüz kaydedilmemiş kanalı da kabul eder.
        let r = device.openRFCOMMChannelAsync(&ch, withChannelID: P3Controller.controlChannel, delegate: self)
        NSLog("Tuneport: açma çağrısı döndü: %d, kanal: %@, durum: %@", Int(r), ch == nil ? "yok" : "var", String(describing: connection))
        if r == kIOReturnSuccess {
            if channel == nil { channel = ch }
            watchDisconnect(of: device)
            if connection == .connected { return }   // bildirim zaten geldi
            // Kulaklık yeni bağlandıysa kanal açma isteği cevapsız kalabilir: zaman aşımı + yeniden deneme
            let opening = ch
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.channel === opening, self.connection == .connecting else { return }
                NSLog("Tuneport: 6 sn içinde cevap gelmedi, kanal kapatılıp yeniden denenecek")
                self.closeControlChannel()
                self.connectAttempts += 1
                if self.connectAttempts == 3 {
                    // Kulaklıktaki kontrol kanalı takılı kalmış olabilir: Bluetooth bağlantısını sıfırla
                    self.resetLink(device)
                } else if self.connectAttempts <= 5 {
                    self.connect()
                } else {
                    self.connectAttempts = 0
                    self.connection = .failed(L("Could not reach the earbuds"))
                }
            }
        } else {
            isOpening = false
            connection = .failed(String(format: L("Could not open channel (%d)"), Int(r)))
        }
    }

    /// Bluetooth bağlantısını kesip yeniden kurar (kılıfa koyup çıkarmanın yazılımla yapılanı)
    private func resetLink(_ device: IOBluetoothDevice) {
        NSLog("Tuneport: kontrol kanalı cevap vermiyor, Bluetooth bağlantısı sıfırlanıyor")
        connection = .connecting
        disconnectNotification?.unregister()
        disconnectNotification = nil
        device.closeConnection()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let r = device.openConnection(self)   // sonuç connectionComplete(_:status:) ile gelir
            if r != kIOReturnSuccess {
                self.connection = .failed(String(format: L("Could not connect (%d)"), Int(r)))
            }
        }
    }

    private func watchDisconnect(of device: IOBluetoothDevice) {
        disconnectNotification?.unregister()
        disconnectNotification = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDidDisconnect(_:device:)))
    }

    @objc private func deviceDidDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Geçiş sırasında bırakılan eski cihazın bildirimi yeni cihazı etkilemesin
        guard device.addressString == targetDevice()?.addressString else { refreshDeviceList(); return }
        closeControlChannel()
        state = nil
        connection = .disconnected
        refreshDeviceList()
    }

    @objc private func deviceDidConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard P3Controller.isSoundcore(device) else { return }
        connectAttempts = 0
        // Kulaklık ses profillerini kurarken birkaç saniye meşgul; biraz bekle
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshDeviceList()
            self?.connect()
            self?.micGuard.enforce()
        }
    }

    /// Bu kanal bizim şu an kullandığımız (ya da açmakta olduğumuz) kanal mı?
    private func isCurrent(_ ch: IOBluetoothRFCOMMChannel!) -> Bool {
        if ch === channel { return true }
        if isOpening && channel == nil {
            channel = ch   // açma çağrısı dönmeden gelen bildirim
            return true
        }
        return false
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        NSLog("Tuneport: kanal açılma bildirimi: %d (güncel: %@)", Int(error), rfcommChannel === channel || (isOpening && channel == nil) ? "evet" : "hayır")
        guard isCurrent(rfcommChannel) else { return }
        isOpening = false
        if error == kIOReturnSuccess {
            connectAttempts = 0
            connection = .connected
            requestState()
        } else {
            channel = nil
            connection = .failed(String(format: L("Connection error (%d)"), Int(error)))
        }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        NSLog("Tuneport: kanal kapandı (güncel: %@)", rfcommChannel === channel ? "evet" : "hayır")
        guard rfcommChannel === channel else { return }
        isOpening = false
        channel = nil
        connection = .disconnected
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard isCurrent(rfcommChannel) else { NSLog("Tuneport: eski kanaldan %d byte yok sayıldı", dataLength); return }
        let p = dataPointer.assumingMemoryBound(to: UInt8.self)
        let bytes = Array(UnsafeBufferPointer(start: p, count: dataLength))
        for (cmd, body) in parser.feed(bytes) { handle(cmd, body) }
    }

    // MARK: Gelen paketler

    private func handle(_ cmd: Command, _ body: [UInt8]) {
        if cmd == .requestState {
            guard let s = P3State(body) else { NSLog("Tuneport: durum paketi çözülemedi (%d byte)", body.count); return }
            state = s
            if !isEditingEQ { eqDraft = s.eqDecibels }
            // Telefondan yapılmış özel EQ'yu ilk görüşte yedekle
            if s.eqProfile == Equalizer.customProfileID && savedCustomEQ == nil {
                savedCustomEQ = s.eqLeft.map { Int($0) - 120 }
            }
        } else {
            // Kulaklıktan gelen bildirim (mod değişti, pil vb.) ya da komut onayı
            scheduleRefresh()
        }
    }

    private func scheduleRefresh(after delay: Double = 0.4) {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.refreshPending = false
            self?.requestState()
        }
    }

    private func send(_ cmd: Command, _ body: [UInt8] = []) {
        guard let ch = channel, isConnected else { return }
        var pkt = Packet.build(cmd, body)
        let r = pkt.withUnsafeMutableBytes { ch.writeSync($0.baseAddress, length: UInt16($0.count)) }
        if r != kIOReturnSuccess { connection = .failed(String(format: L("Send error (%d)"), Int(r))) }
    }

    // MARK: Komutlar

    func refresh() {
        refreshDeviceList()
        if isConnected {
            requestState()
        } else {
            // Yarım kalmış bir bağlantı denemesi varsa bırak, baştan dene
            closeControlChannel()
            connectAttempts = 0
            connect()
        }
    }

    func requestState() { send(.requestState) }

    func setAmbient(_ mode: AmbientMode) { setSoundModes(ambient: mode.rawValue) }
    func setNoiseCanceling(_ mode: NoiseCancelingMode) { setSoundModes(nc: mode.rawValue) }
    func setTransparency(_ mode: TransparencyMode) { setSoundModes(trans: mode.rawValue) }

    private func setSoundModes(ambient: UInt8? = nil, nc: UInt8? = nil, trans: UInt8? = nil) {
        guard var s = state else { return }
        s.ambient = ambient ?? s.ambient
        s.noiseCanceling = nc ?? s.noiseCanceling
        s.transparency = trans ?? s.transparency
        state = s
        send(.setSoundModes, [s.ambient, s.noiseCanceling, s.transparency, s.customNoiseCanceling])
        scheduleRefresh(after: 0.6)
    }

    func applyDraftEQ() {
        sendEQ(profileID: Equalizer.customProfileID, tenths: Equalizer.tenths(fromDecibels: eqDraft))
    }

    func applyPreset(_ preset: EQPreset) {
        sendEQ(profileID: preset.id, tenths: preset.values)
    }

    func applySavedCustomEQ() {
        guard let saved = savedCustomEQ, saved.count >= 8 else { return }
        sendEQ(profileID: Equalizer.customProfileID, tenths: Array(saved.prefix(8)) + [0, 0])
    }

    func saveCurrentAsCustom() {
        savedCustomEQ = Equalizer.tenths(fromDecibels: eqDraft)
        objectWillChange.send()
    }

    func resetEQ() {
        sendEQ(profileID: Equalizer.customProfileID, tenths: Array(repeating: 0, count: 10))
    }

    private func sendEQ(profileID: UInt16, tenths: [Int]) {
        if var s = state {
            s.eqProfile = profileID
            state = s
        }
        eqDraft = tenths.prefix(8).map { Double($0) / 10 }
        send(.setEQWithDRC, Equalizer.body(profileID: profileID, tenths: tenths))
        scheduleRefresh(after: 0.6)
    }
}
