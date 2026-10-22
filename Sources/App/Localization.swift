// SPDX-License-Identifier: GPL-3.0-or-later
// Dil yönetimi
//
// Arayüz metinleri İngilizce yazılır; İngilizce metin aynı zamanda çeviri anahtarıdır.
// Çeviriler Resources/<dil>.lproj/Localizable.strings dosyalarındadır.
// Dil, uygulama içinden anında (yeniden başlatmadan) değiştirilebilir; bu yüzden tüm
// metinler macOS'un otomatik çevirisi yerine L() üzerinden geçer.

import Foundation
import SwiftUI

struct AppLanguage: Identifiable, Hashable {
    let code: String        // .lproj klasör adı
    let nativeName: String  // dilin kendi dilindeki adı
    var id: String { code }
}

final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    static let systemCode = "system"

    static let available: [AppLanguage] = [
        AppLanguage(code: "en", nativeName: "English"),
        AppLanguage(code: "tr", nativeName: "Türkçe"),
        AppLanguage(code: "de", nativeName: "Deutsch"),
        AppLanguage(code: "es", nativeName: "Español"),
        AppLanguage(code: "fr", nativeName: "Français"),
        AppLanguage(code: "it", nativeName: "Italiano"),
        AppLanguage(code: "pt-BR", nativeName: "Português (Brasil)"),
        AppLanguage(code: "pl", nativeName: "Polski"),
        AppLanguage(code: "ru", nativeName: "Русский"),
        AppLanguage(code: "uk", nativeName: "Українська"),
        AppLanguage(code: "id", nativeName: "Bahasa Indonesia"),
        AppLanguage(code: "ar", nativeName: "العربية"),
        AppLanguage(code: "he", nativeName: "עברית"),
        AppLanguage(code: "bn", nativeName: "বাংলা"),
        AppLanguage(code: "ja", nativeName: "日本語"),
        AppLanguage(code: "ko", nativeName: "한국어"),
        AppLanguage(code: "zh-Hans", nativeName: "简体中文"),
    ]

    /// Kullanıcının seçimi: "system" ya da bir dil kodu
    @Published var selection: String {
        didSet {
            UserDefaults.standard.set(selection, forKey: "appLanguage")
            reload()
        }
    }

    /// Şu an etkin olan dil kodu
    @Published private(set) var activeCode = "en"
    private(set) var bundle: Bundle = .main

    private init() {
        selection = UserDefaults.standard.string(forKey: "appLanguage") ?? LanguageManager.systemCode
        reload()
    }

    private func reload() {
        let code: String
        if selection == LanguageManager.systemCode {
            let supported = LanguageManager.available.map(\.code)
            code = Bundle.preferredLocalizations(from: supported, forPreferences: Locale.preferredLanguages).first ?? "en"
        } else {
            code = selection
        }
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) {
            bundle = b
            activeCode = code
        } else {
            bundle = .main
            activeCode = "en"
        }
    }

    var isRightToLeft: Bool {
        Locale.Language(identifier: activeCode).characterDirection == .rightToLeft
    }

    var locale: Locale { Locale(identifier: activeCode) }

    func localized(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// Seçili dilde metin
func L(_ key: String) -> String {
    LanguageManager.shared.localized(key)
}

/// "60%", "%60", "60 %" gibi dile göre yüzde biçimi
func percentText(_ value: Int) -> String {
    String(format: L("%d%%"), value)
}
