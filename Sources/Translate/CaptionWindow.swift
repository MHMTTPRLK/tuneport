// SPDX-License-Identifier: GPL-3.0-or-later
// Ekranın altında yüzen canlı altyazı penceresi ve çeviri oturumu
//
// Apple'ın Translation çerçevesinde çeviri oturumu bir SwiftUI görünümüne bağlı yaşar
// (.translationTask). Bu yüzden çeviri, altyazı penceresinin içinde yapılır.

import SwiftUI
import AppKit
#if canImport(Translation)
import Translation
#endif

final class CaptionWindowController {
    static let shared = CaptionWindowController()

    /// Derlendiği SDK Translation çerçevesini içeriyor mu
    static var translationFrameworkAvailable: Bool {
        #if canImport(Translation)
        return true
        #else
        return false
        #endif
    }

    private var panel: NSPanel?

    enum LanguageState { case ready, needsDownload, unsupported }

    /// Dil çifti için çeviri paketleri yüklü mü?
    static func languageState(from source: String, to target: String) async -> LanguageState {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: source),
                to: Locale.Language(identifier: target))
            switch status {
            case .installed: return .ready
            case .supported: return .needsDownload
            case .unsupported: return .unsupported
            @unknown default: return .ready
            }
        }
        #endif
        return .unsupported
    }

    func show(translator: LiveTranslator) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 260),
                            styleMask: [.nonactivatingPanel, .borderless, .resizable],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            let root = CaptionView()
                .environmentObject(translator)
                .environmentObject(LanguageManager.shared)
            p.contentView = NSHostingView(rootView: AnyView(root))
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.midX - 380, y: f.minY + 40))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil   // çeviri oturumu da kapanır
    }
}

// MARK: - Altyazı görünümü

struct CaptionView: View {
    @EnvironmentObject var translator: LiveTranslator
    @EnvironmentObject var lang: LanguageManager

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ForEach(translator.captions.suffix(2)) { c in
                VStack(spacing: 2) {
                    if let t = c.translated {
                        Text(t)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(c.original)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if translator.showOriginal, c.translated != nil {
                        Text(c.original)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.center)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !translator.partialText.isEmpty {
                Text(translator.partialText)
                    .font(.system(size: 14).italic())
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else if translator.captions.isEmpty {
                Text(L("Listening…"))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if let err = translator.errorMessage {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: 740)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.72)))
        .overlay(alignment: .topTrailing) {
            Button { translator.stop() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(8)
            .help(L("Stop"))
        }
        .animation(.easeOut(duration: 0.2), value: translator.captions)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.layoutDirection, lang.isRightToLeft ? .rightToLeft : .leftToRight)
        .modifier(TranslationHostModifier(translator: translator))
    }
}

// MARK: - Dil paketi indirme (panel penceresinde)

/// macOS'un dil paketi indirme penceresi odak alabilen bir pencerede gösterilmeli;
/// bu yüzden indirme, menü çubuğu panelinin içinden başlatılır.
struct LanguageDownloadModifier: ViewModifier {
    @ObservedObject var translator: LiveTranslator

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            content.modifier(LanguageDownloadHost(translator: translator))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
struct LanguageDownloadHost: ViewModifier {
    @ObservedObject var translator: LiveTranslator
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                do {
                    try await session.prepareTranslation()
                    await MainActor.run { translator.languagesDownloaded() }
                } catch {
                    NSLog("Tuneport: dil paketi hazırlanamadı: %@", String(describing: error))
                }
            }
            .onChange(of: translator.downloadRequest) { _ in
                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: Locale.Language(identifier: translator.sourceLanguage),
                        target: Locale.Language(identifier: translator.targetLanguage))
                } else {
                    configuration?.invalidate()
                }
            }
    }
}
#endif

// MARK: - Çeviri oturumu

/// macOS 15+ ve SDK uygunsa çeviri oturumunu kurar; değilse hiçbir şey yapmaz
struct TranslationHostModifier: ViewModifier {
    let translator: LiveTranslator

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            content.modifier(TranslationHost(translator: translator))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
struct TranslationHost: ViewModifier {
    @ObservedObject var translator: LiveTranslator
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                await TranslationHost.run(session: session, translator: translator)
            }
            .onAppear { rebuild() }
            .onChange(of: translator.configurationVersion) { _ in rebuild() }
            .onChange(of: translator.sourceLanguage) { _ in rebuild() }
    }

    private func rebuild() {
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: translator.sourceLanguage),
            target: Locale.Language(identifier: translator.targetLanguage))
    }

    @MainActor
    static func run(session: TranslationSession, translator: LiveTranslator) async {
        // Gerekirse dil paketini indirme izni ister (macOS'un kendi penceresi)
        try? await session.prepareTranslation()
        while !Task.isCancelled {
            guard let req = translator.nextRequest() else {
                try? await Task.sleep(nanoseconds: 150_000_000)
                continue
            }
            if translator.isSameLanguage {
                translator.didTranslate(req.captionID, text: req.text)
                continue
            }
            do {
                let response = try await session.translate(req.text)
                translator.didTranslate(req.captionID, text: response.targetText)
            } catch {
                NSLog("Tuneport: çeviri hatası: %@", String(describing: error))
                translator.translationFailed(error.localizedDescription)
            }
        }
    }
}
#endif
