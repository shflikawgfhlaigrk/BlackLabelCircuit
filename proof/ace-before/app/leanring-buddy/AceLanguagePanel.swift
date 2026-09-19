#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// Recovery must stay reachable when the chosen recognizer is unavailable.
struct AceLanguagePanel: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var selectedLanguage = AceLanguage.selected()
    @State private var languageStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LANGUAGE").font(.system(size: 9, weight: .bold))
            Picker("Conversation language", selection: $selectedLanguage) {
                ForEach(AceLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .accessibilityIdentifier("ace.language.selection")
            AceTrackedButton("Use language") {
                if companionManager.changeConversationLanguage(selectedLanguage) {
                    languageStatus = "Using " + selectedLanguage.resolved().displayName
                } else {
                    languageStatus = "End Partner and finish dictation, active work or notes first."
                }
            }
            .disabled(!companionManager.canChangeConversationLanguage)
            .accessibilityIdentifier("ace.language.apply")
            Text(languageStatus.isEmpty
                 ? "Current: " + AceLanguage.current.displayName : languageStatus)
            Text("Changes replies and local speech. App controls remain in English.")
            if companionManager.appleSpeechRecognitionReadiness.isReady {
                Text("On-device dictation ready: " + AceLanguage.current.displayName)
            } else {
                Text("Dictation for " + AceLanguage.current.displayName + ": "
                     + (companionManager.appleSpeechRecognitionReadiness.unavailableExplanation
                        ?? "not available on this Mac.")
                     + " Select English here, or enable this language in macOS Keyboard > Dictation and finish its download.")
            }
            Text("Stop: “" + AceLanguage.current.stopPhrase
                 + "”. Exit Stealth: hold Command + Shift and say “"
                 + AceLanguage.current.exitPhrase + "”.")
        }
        .font(.system(size: 10))
        .foregroundColor(DS.Colors.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif // circuit-convert
