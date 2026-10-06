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
            QuickMeal.sharedStore?.lastOutcome = nil
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
            // Claimed before any await: a second tap, or a Cancel, now finds nothing to act on.
            guard let store = QuickMeal.sharedStore, let pending = store.claimPending() else {
                WidgetCenter.shared.reloadTimelines(ofKind: QuickMeal.widgetKind)
                return .result()
            }
            let request = MealIntentRequest()
            let (recommended, glucoseDate) = await request.recommendation(carbs: pending.carbs)
            let units = request.bolusAllowed ? recommended : 0
            var message: String?
            switch QuickMeal.confirmCheck(pending: pending, freshUnits: units, glucoseDate: glucoseDate, now: Date()) {
            case .go:
                message = await logAndBolus(request: request, carbs: pending.carbs, units: units)
            case let .changed(newUnits):
                store.pending = QuickMeal.Pending(carbs: pending.carbs, units: newUnits, createdAt: Date())
            case .stale:
                message = String(localized: "Not logged: glucose is over 15 min old")
            case .expired:
                message = String(localized: "Not logged: the confirm expired. Tap again.")
            }
            if let message { store.lastOutcome = QuickMeal.Outcome(message: message, date: Date()) }
            WidgetCenter.shared.reloadTimelines(ofKind: QuickMeal.widgetKind)
        #endif
        return .result()
    }

    #if !WIDGET_EXTENSION
        /// Logs the carbs, then sends the bolus; returns the line the widget shows, whatever happened.
        @MainActor private func logAndBolus(request: MealIntentRequest, carbs: Decimal, units: Decimal) async -> String {
            let grams = carbs.formatted()
            do {
                try await request.logCarbs(carbs)
            } catch {
                return String(localized: "Nothing logged: \(error.localizedDescription)")
            }
            guard units > 0 else { return String(localized: "Logged \(grams) g. No bolus.") }
            do {
                let outcome = try await request.bolus(units)
                if outcome.sent { return String(localized: "Logged \(grams) g. ") + outcome.message }
                return String(localized: "Logged \(grams) g. Bolus NOT given: \(outcome.reason ?? outcome.message)")
            } catch {
                return String(localized: "Logged \(grams) g. Bolus NOT given: \(error.localizedDescription)")
            }
        }
    #endif
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
