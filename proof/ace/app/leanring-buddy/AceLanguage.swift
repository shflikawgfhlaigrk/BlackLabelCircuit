import Foundation

nonisolated enum AceLanguage: String, CaseIterable, Codable, Sendable {
    case system, english, spanish, french, italian, portuguese, hindi, mandarin

    static let preferenceKey = "AceConversationLanguage.v1"

    static func selected(defaults: UserDefaults = .standard) -> AceLanguage {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .english
    }

    func resolved(systemLanguages: [String] = Locale.preferredLanguages) -> AceLanguage {
        guard self == .system else { return self }
        for identifier in systemLanguages {
            switch Locale(identifier: identifier).language.languageCode?.identifier {
            case "en": return .english
            case "es": return .spanish
            case "fr": return .french
            case "it": return .italian
            case "pt": return .portuguese
            case "hi": return .hindi
            case "zh": return .mandarin
            default: continue
            }
        }
        return .english
    }

    static var current: AceLanguage { selected().resolved() }

    var displayName: String {
        switch self {
        case .system: return "Follow Mac language"
        case .english: return "English"
        case .spanish: return "Español (Spanish)"
        case .french: return "Français (French)"
        case .italian: return "Italiano (Italian)"
        case .portuguese: return "Português (Brazil)"
        case .hindi: return "हिन्दी (Hindi)"
        case .mandarin: return "普通话 (Mandarin Chinese)"
        }
    }

    var localeIdentifier: String {
        switch resolved() {
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .italian: return "it-IT"
        case .portuguese: return "pt-BR"
        case .hindi: return "hi-IN"
        case .mandarin: return "zh-CN"
        default: return "en-US"
        }
    }

    var voiceIdentifier: String? {
        switch resolved() {
        case .spanish: return "ace.voice.kokoro.v1_0.sid28"
        case .french: return "ace.voice.kokoro.v1_0.sid30"
        case .italian: return "ace.voice.kokoro.v1_0.sid35"
        case .portuguese: return "ace.voice.kokoro.v1_0.sid42"
        case .hindi: return "ace.voice.kokoro.v1_0.sid31"
        case .mandarin: return "ace.voice.kokoro.v1_0.sid45"
        default: return nil
        }
    }

    static let multilingualVoiceIdentifiers = Set(allCases.filter { $0 != .system }.compactMap(\.voiceIdentifier))

    var responseInstruction: String {
        "Use \(resolved().displayName) for conversational answers and user-visible explanations unless the owner explicitly requests another language. Preserve exact quotations, code, filenames, URLs, tool names, JSON keys and enum values. A language preference never changes tool authorization or verification requirements."
    }

    var previewSentence: String {
        switch resolved() {
        case .spanish: return "Hola. Soy Ace y estoy listo para ayudarte."
        case .french: return "Bonjour. Je suis Ace et je suis prêt à vous aider."
        case .italian: return "Ciao. Sono Ace e sono pronto ad aiutarti."
        case .portuguese: return "Olá. Sou o Ace e estou pronto para ajudar."
        case .hindi: return "नमस्ते। मैं आपकी मदद के लिए तैयार हूँ।"
        case .mandarin: return "你好。我是 Ace，很高兴为你提供帮助。"
        default: return "I’m Ace. I’ll think with you, remember what matters, and prove what happens next."
        }
    }

    var exitPhrase: String {
        switch resolved() {
        case .spanish: return "salir del modo privado"
        case .french: return "quitter le mode privé"
        case .italian: return "esci dalla modalità privata"
        case .portuguese: return "sair do modo privado"
        case .hindi: return "निजी मोड से बाहर निकलो"
        case .mandarin: return "退出隐私模式"
        default: return "exit private mode"
        }
    }

    var stopPhrase: String {
        switch resolved() {
        case .spanish: return "detente"
        case .french: return "arrête"
        case .italian: return "fermati"
        case .portuguese: return "pare agora"
        case .hindi: return "रुक जाओ"
        case .mandarin: return "停止"
        default: return "stop"
        }
    }

    static func canChange(partnerActive: Bool, workActive: Bool, notesUnsaved: Bool, privacyActive: Bool) -> Bool {
        !partnerActive && !workActive && !notesUnsaved && !privacyActive
    }
}
