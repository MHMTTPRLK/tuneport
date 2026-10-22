// SPDX-License-Identifier: GPL-3.0-or-later
// Canlı çeviri: ses → konuşma tanıma → cümle bölütleme → çeviri → altyazı (ve isteğe bağlı seslendirme)
//
// Her şey cihaz içinde çalışır: konuşma tanıma Apple'ın cihaz içi modeliyle, çeviri Apple'ın
// Translation çerçevesiyle (macOS 15+) yapılır. Ses kaydedilmez, hiçbir yere gönderilmez.

import Foundation
import AVFoundation
import Speech

struct Caption: Identifiable, Equatable {
    let id = UUID()
    var original: String
    var translated: String?
}

/// Çeviri hattındaki tek bir istek (altyazı penceresindeki çeviri oturumu tarafından işlenir)
struct TranslationRequest {
    let captionID: UUID
    let text: String
}

final class LiveTranslator: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case systemAudio, microphone
        var id: String { rawValue }
    }

    /// Konuşma tanıma için desteklediğimiz kaynak diller (konuşma tanıma yerel ayarı)
    static let sourceLanguages = ["en-US", "en-GB", "tr-TR", "de-DE", "fr-FR", "es-ES", "it-IT",
                                  "pt-BR", "ru-RU", "ja-JP", "ko-KR", "zh-CN"]
    /// Çeviri hedef dilleri
    static let targetLanguages = ["tr", "en", "de", "fr", "es", "it", "pt", "ru", "ja", "ko", "zh-Hans"]

    @Published private(set) var isRunning = false
    @Published private(set) var captions: [Caption] = []
    @Published private(set) var partialText = ""
    @Published private(set) var errorMessage: String?
    /// Dil paketleri eksik: panelde "Dilleri indir" düğmesi gösterilir
    @Published private(set) var needsLanguageDownload = false
    /// Panel bunu izler; her artışta indirme penceresini açar
    @Published private(set) var downloadRequest = 0

    @Published var source: Source {
        didSet { save(source.rawValue, "translateSource"); restartIfRunning() }
    }
    @Published var sourceLanguage: String {
        didSet { save(sourceLanguage, "translateSourceLanguage"); restartIfRunning() }
    }
    @Published var targetLanguage: String {
        didSet { save(targetLanguage, "translateTargetLanguage"); configurationVersion += 1 }
    }
    @Published var speakTranslation: Bool {
        didSet { save(speakTranslation, "translateSpeak") }
    }
    @Published var showOriginal: Bool {
        didSet { save(showOriginal, "translateShowOriginal") }
    }
    /// Dil çifti değişince altyazı penceresi çeviri oturumunu yeniden kurar
    @Published private(set) var configurationVersion = 0

    /// Çeviri bekleyen cümleler (altyazı penceresindeki çeviri oturumu sırayla alır)
    private var queue: [TranslationRequest] = []

    private var audio: AudioSource?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committedLength = 0
    private var commitTimer: Timer?
    private var restartTimer: Timer?
    private let synthesizer = AVSpeechSynthesizer()
    private let requestLock = NSLock()

    init() {
        let d = UserDefaults.standard
        source = Source(rawValue: d.string(forKey: "translateSource") ?? "") ?? .systemAudio
        sourceLanguage = d.string(forKey: "translateSourceLanguage") ?? "en-US"
        targetLanguage = d.string(forKey: "translateTargetLanguage") ?? "tr"
        speakTranslation = d.object(forKey: "translateSpeak") as? Bool ?? false
        showOriginal = d.object(forKey: "translateShowOriginal") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    static var isAvailable: Bool {
        if #available(macOS 15, *) { return CaptionWindowController.translationFrameworkAvailable }
        return false
    }

    // MARK: Başlat / durdur

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        Task { @MainActor in
            do {
                if !isSameLanguage {
                    switch await CaptionWindowController.languageState(from: sourceLanguage, to: targetLanguage) {
                    case .ready:
                        needsLanguageDownload = false
                    case .needsDownload:
                        needsLanguageDownload = true
                        errorMessage = L("Translation languages need to be downloaded")
                        return
                    case .unsupported:
                        errorMessage = L("This language pair isn't supported")
                        return
                    }
                }
                try await requestSpeechPermission()
                try startRecognition()
                let audio: AudioSource
                if source == .systemAudio {
                    audio = SystemAudioCapture()
                } else {
                    audio = MicrophoneCapture()
                }
                audio.onBuffer = { [weak self] buffer in
                    guard let self else { return }
                    self.requestLock.lock()
                    self.request?.append(buffer)
                    self.requestLock.unlock()
                }
                try await audio.start()
                self.audio = audio
                isRunning = true
                CaptionWindowController.shared.show(translator: self)
            } catch {
                stop()
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        audio?.stop()
        audio = nil
        stopRecognition()
        commitPending()
        isRunning = false
        partialText = ""
        CaptionWindowController.shared.hide()
    }

    private func restartIfRunning() {
        guard isRunning else { return }
        stop()
        start()
    }

    private func requestSpeechPermission() async throws {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw NSError(domain: "Tuneport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("Speech recognition permission is required")])
        }
    }

    // MARK: Konuşma tanıma

    private func startRecognition() throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: sourceLanguage)),
              recognizer.isAvailable else {
            throw NSError(domain: "Tuneport", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L("Speech recognition is not available for this language")])
        }
        self.recognizer = recognizer
        beginTask()
        // Uzun oturumlarda tanıma görevini düzenli yenile (tek görev sınırsız sürmüyor)
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            self?.rollTask()
        }
    }

    private func beginTask() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        requestLock.lock()
        request = req
        requestLock.unlock()
        committedLength = 0
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.handle(result: result, error: error, for: req)
            }
        }
    }

    private var lastRoll = Date.distantPast
    private var rollScheduled = false

    /// Mevcut görevi kapatıp yenisini başlat (bekleyen metin önce gönderilir)
    private func rollTask() {
        // Tanıma art arda hata verirse döngüye girmesin
        guard Date().timeIntervalSince(lastRoll) > 1 else {
            guard !rollScheduled else { return }
            rollScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.rollScheduled = false
                guard self.isRunning else { return }
                self.lastRoll = .distantPast
                self.rollTask()
            }
            return
        }
        lastRoll = Date()
        commitPending()
        let old = request
        let oldTask = task
        beginTask()
        old?.endAudio()
        oldTask?.finish()
    }

    private func stopRecognition() {
        restartTimer?.invalidate()
        restartTimer = nil
        commitTimer?.invalidate()
        commitTimer = nil
        requestLock.lock()
        request?.endAudio()
        request = nil
        requestLock.unlock()
        task?.cancel()
        task = nil
        recognizer = nil
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, for req: SFSpeechAudioBufferRecognitionRequest) {
        guard req === request else { return }   // eski göreve ait geç sonuç
        if let result {
            let full = result.bestTranscription.formattedString
            let pending = full.count > committedLength ? String(full.dropFirst(committedLength)) : ""
            partialText = pending.trimmingCharacters(in: .whitespaces)

            if result.isFinal {
                commitPending(full: full)
                rollTask()
                return
            }
            // Cümle bittiyse hemen, bitmediyse kısa bir sessizlikten sonra çeviriye gönder
            if let last = partialText.last, ".?!。？！".contains(last), partialText.count > 3 {
                commitPending(full: full)
            } else {
                commitTimer?.invalidate()
                commitTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                    self?.commitPending(full: full)
                }
            }
        } else if error != nil, isRunning {
            // Sessizlik ya da kesinti sonrası görev bitebilir: sessizce yenile
            rollTask()
        }
    }

    /// Henüz gönderilmemiş metni altyazı olarak ekle ve çeviriye gönder
    private func commitPending(full: String? = nil) {
        commitTimer?.invalidate()
        commitTimer = nil
        let text = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let full { committedLength = full.count }
        partialText = ""
        guard text.count > 1 else { return }

        let caption = Caption(original: text, translated: nil)
        captions.append(caption)
        if captions.count > 4 { captions.removeFirst(captions.count - 4) }
        queue.append(TranslationRequest(captionID: caption.id, text: text))
    }

    // MARK: Çeviri sonucu

    /// Sıradaki çeviri isteği (yoksa nil)
    func nextRequest() -> TranslationRequest? {
        queue.isEmpty ? nil : queue.removeFirst()
    }

    /// Altyazı penceresindeki çeviri oturumu çeviriyi tamamlayınca çağırır
    func didTranslate(_ captionID: UUID, text: String) {
        guard let i = captions.firstIndex(where: { $0.id == captionID }) else { return }
        captions[i].translated = text
        if speakTranslation { speak(text) }
    }

    func requestLanguageDownload() {
        downloadRequest += 1
    }

    func languagesDownloaded() {
        needsLanguageDownload = false
        errorMessage = nil
    }

    func translationFailed(_ message: String) {
        errorMessage = message
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: targetLanguage == "zh-Hans" ? "zh-CN" : targetLanguage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synthesizer.speak(utterance)
    }

    /// Kaynak ve hedef aynı dilse çeviriye gerek yok (sadece altyazı)
    var isSameLanguage: Bool {
        sourceLanguage.prefix(2) == targetLanguage.prefix(2)
    }

    // MARK: Görünen adlar

    func displayName(forLanguage code: String) -> String {
        let locale = LanguageManager.shared.locale
        return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }
}
