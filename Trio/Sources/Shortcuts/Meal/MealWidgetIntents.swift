import AppIntents
import Foundation

// Intents shown as buttons on the Live Activity and the Meal widget. This file is compiled into the
// app and the LiveActivity extension; iOS runs a LiveActivityIntent's perform() in the app's process,
// so the bodies are compiled only there (WIDGET_EXTENSION is set on the extension target).

@available(iOS 17.0, *)
struct OpenMealIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Open meal entry"
    static var openAppWhenRun = true
    static var isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
            TrioApp.resolver.resolve(Router.self)!.mainModalScreen.send(.treatmentView)
        #endif
        return .result()
    }
}
