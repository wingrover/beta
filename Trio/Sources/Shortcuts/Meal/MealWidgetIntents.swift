import AppIntents
import Foundation
import WidgetKit

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

@available(iOS 17.0, *)
struct MealPresetIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Meal preset"
    static var isDiscoverable = false
    @Parameter(title: "Carbs") var carbs: Int
    init() {}
    init(carbs: Int) { self.carbs = carbs }

    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
            let request = MealIntentRequest()
            let (recommended, _) = await request.recommendation(carbs: Decimal(carbs))
            // With bolus via Shortcuts off, the card must say "no bolus" rather than promise one it cannot send.
            let units = request.bolusAllowed ? recommended : 0
            QuickMeal.sharedStore?.pending = QuickMeal.Pending(carbs: Decimal(carbs), units: units, createdAt: Date())
            WidgetCenter.shared.reloadTimelines(ofKind: QuickMeal.widgetKind)
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct MealConfirmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Confirm meal"
    static var isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
            guard let store = QuickMeal.sharedStore, let pending = store.pending else { return .result() }
            let request = MealIntentRequest()
            let (recommended, glucoseDate) = await request.recommendation(carbs: pending.carbs)
            let units = request.bolusAllowed ? recommended : 0
            switch QuickMeal.confirmCheck(pending: pending, freshUnits: units, glucoseDate: glucoseDate, now: Date()) {
            case .go:
                store.pending = nil
                try await request.logCarbs(pending.carbs)
                if units > 0 { _ = try await request.bolus(units) }
            case let .changed(newUnits):
                store.pending = QuickMeal.Pending(carbs: pending.carbs, units: newUnits, createdAt: Date())
            case .expired,
                 .stale:
                store.pending = nil
            }
            WidgetCenter.shared.reloadTimelines(ofKind: QuickMeal.widgetKind)
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct MealCancelIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Cancel meal"
    static var isDiscoverable = false

    @MainActor func perform() async throws -> some IntentResult {
        QuickMeal.sharedStore?.pending = nil
        WidgetCenter.shared.reloadTimelines(ofKind: QuickMeal.widgetKind)
        return .result()
    }
}
