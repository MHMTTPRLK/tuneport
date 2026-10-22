// SPDX-License-Identifier: GPL-3.0-or-later
// "Şu an çalıyor" bilgisi ve oynatma kontrolleri
//
// 1. yol: macOS'un sistem geneli "Şu an oynatılan" bilgisi (MediaRemote). Spotify, Apple Music,
//    tarayıcıdaki YouTube vb. her kaynağı kapsar. Özel bir sistem çerçevesi olduğu için çalışma
//    anında yüklenir; erişilemezse sessizce 2. yola düşülür.
// 2. yol: Çalışıyorsa Spotify ya da Apple Music'e AppleScript ile sorulur (uygulamayı açmaz).

import Foundation
import AppKit

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var isPlaying: Bool
    var artwork: NSImage?
    var appName: String?

    static func == (a: NowPlayingInfo, b: NowPlayingInfo) -> Bool {
        a.title == b.title && a.artist == b.artist && a.isPlaying == b.isPlaying && a.appName == b.appName
            && (a.artwork == nil) == (b.artwork == nil)
    }
}

final class NowPlaying: ObservableObject {
    @Published private(set) var info: NowPlayingInfo?

    private var timer: Timer?
    private let remote = MediaRemote()
    /// Sistem geneli bilgi en az bir kez geldiyse AppleScript yedeğine gerek yok
    private var remoteWorks = false

    init() {
        remote.register { [weak self] in self?.refresh() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        remote.fetch { [weak self] remoteInfo in
            guard let self else { return }
            if remoteInfo != nil { self.remoteWorks = true }
            let result = remoteInfo ?? (self.remoteWorks ? nil : ScriptablePlayer.current())
            if result != self.info { self.info = result }
        }
    }

    // MARK: Kontroller

    func togglePlayPause() { command(.togglePlayPause) }
    func next() { command(.next) }
    func previous() { command(.previous) }

    private func command(_ c: MediaRemote.Command) {
        if remote.isAvailable && remote.send(c) {
            // MediaRemote başarılı
        } else {
            ScriptablePlayer.send(c, to: info?.appName)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
    }
}

// MARK: - MediaRemote (sistem geneli)

final class MediaRemote {
    enum Command: UInt32 {
        case play = 0, pause = 1, togglePlayPause = 2, next = 4, previous = 5
    }

    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SendCommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool

    private var getInfo: GetInfoFn?
    private var registerFn: RegisterFn?
    private var sendCommand: SendCommandFn?
    private var observers: [NSObjectProtocol] = []

    var isAvailable: Bool { getInfo != nil }

    init() {
        let url = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL) else { return }
        if let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            getInfo = unsafeBitCast(p, to: GetInfoFn.self)
        }
        if let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            registerFn = unsafeBitCast(p, to: RegisterFn.self)
        }
        if let p = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            sendCommand = unsafeBitCast(p, to: SendCommandFn.self)
        }
    }

    func register(onChange: @escaping () -> Void) {
        registerFn?(DispatchQueue.main)
        for name in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"] {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSNotification.Name(name), object: nil, queue: .main) { _ in onChange() })
        }
    }

    /// Şu an çalan bilgi; erişilemezse ya da boşsa nil
    func fetch(_ completion: @escaping (NowPlayingInfo?) -> Void) {
        guard let getInfo else { completion(nil); return }
        getInfo(DispatchQueue.main) { dict in
            guard let d = (dict as NSDictionary?) as? [String: Any],
                  let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else {
                completion(nil)
                return
            }
            let artist = d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let rate = d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            let artwork = (d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data).flatMap(NSImage.init(data:))
            completion(NowPlayingInfo(title: title, artist: artist, isPlaying: rate > 0, artwork: artwork, appName: nil))
        }
    }

    func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }
}

// MARK: - Spotify / Apple Music (AppleScript)

enum ScriptablePlayer {
    private static let players: [(bundleID: String, name: String)] = [
        ("com.spotify.client", "Spotify"),
        ("com.apple.Music", "Music"),
    ]

    /// Yalnızca zaten açık olan oynatıcılara sorulur; kapalı uygulama başlatılmaz
    static func current() -> NowPlayingInfo? {
        for p in players where isRunning(p.bundleID) {
            let script = """
            tell application "\(p.name)"
                if player state is stopped then return ""
                return (name of current track) & "\\n" & (artist of current track) & "\\n" & (player state as string)
            end tell
            """
            guard let out = run(script), !out.isEmpty else { continue }
            let parts = out.components(separatedBy: "\n")
            guard parts.count >= 3, !parts[0].isEmpty else { continue }
            return NowPlayingInfo(title: parts[0], artist: parts[1], isPlaying: parts[2] == "playing",
                                  artwork: nil, appName: p.name)
        }
        return nil
    }

    static func send(_ command: MediaRemote.Command, to appName: String?) {
        let target = appName ?? players.first(where: { isRunning($0.bundleID) })?.name
        guard let target else { return }
        let verb: String
        switch command {
        case .next: verb = "next track"
        case .previous: verb = "previous track"
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        }
        _ = run("tell application \"\(target)\" to \(verb)")
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }
}
