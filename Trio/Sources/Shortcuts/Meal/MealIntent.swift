import AppIntents
import Foundation

struct MealIntent: AppIntent {
    static var title = LocalizedStringResource("Log meal with recommended bolus")
    static var description = IntentDescription(.init("Asks for carbs, shows Beta's recommended bolus, and logs both after one confirm."))
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(
        title: LocalizedStringResource("Carbs"),
        controlStyle: .field,
        inclusiveRange: (lowerBound: 1, upperBound: 300),
        requestValueDialog: IntentDialog(stringLiteral: String(localized: "Carbs?"))
    ) var carbs: Int

    @MainActor func perform() async throws -> some ProvidesDialog {
        let request = MealIntentRequest()
        let grams = Decimal(min(carbs, Int(truncating: request.settingsManager.settings.maxCarbs as NSNumber)))
        let (units, glucoseDate) = await request.recommendation(carbs: grams)
        switch QuickMeal.decide(carbs: grams, recommended: units, glucoseDate: glucoseDate, now: Date(),
                                bolusAllowed: request.bolusAllowed) {
        case .stale:
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Glucose is over 15 min old. Nothing was logged; use the app.")))
        case let .carbsOnly(grams, bolusDisabled):
            let ask = bolusDisabled
                ? String(localized: "Log \(grams.formatted()) g? (bolus via Shortcuts is off in settings)")
                : String(localized: "Log \(grams.formatted()) g? (no bolus recommended)")
            try await requestConfirmation(result: .result(dialog: IntentDialog(stringLiteral: ask)))
            try await request.logCarbs(grams)
            return .result(dialog: IntentDialog(stringLiteral: bolusDisabled
                    ? String(localized: "Logged \(grams.formatted()) g. The bolus was not sent: bolus via Shortcuts is off.")
                    : String(localized: "Logged \(grams.formatted()) g.")))
        case let .carbsAndBolus(grams, units):
            try await requestConfirmation(result: .result(dialog: IntentDialog(stringLiteral:
                String(localized: "Log \(grams.formatted()) g and bolus \(units.formatted()) U?"))))
            try await request.logCarbs(grams)
            let reply = try await request.bolus(units)
            return .result(dialog: IntentDialog(stringLiteral: String(localized: "Logged \(grams.formatted()) g. ") + reply))
        }
    }
}
