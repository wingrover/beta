import Foundation

/// Shared by the Meal Shortcut and the Meal widget: works out the dose, logs carbs, sends the bolus
/// through the same safety-checked path as the "Enact Bolus" Shortcut.
final class MealIntentRequest: BaseIntentsRequest {
    private lazy var calculator = TrioApp.resolver.resolve(BolusCalculationManager.self)!

    var bolusAllowed: Bool { settingsManager.settings.bolusShortcut == .limitWithSafetyChecks }

    func recommendation(carbs: Decimal) async -> (units: Decimal, glucoseDate: Date?) {
        // minPredBG: nil makes the calculator read the last determination itself and fall back to 0 (which
        // zeroes the dose) when it is missing, so a failed read fails safe.
        let result = await calculator.handleBolusCalculation(
            carbs: carbs,
            useFattyMealCorrection: false,
            useSuperBolus: false,
            lastLoopDate: apsManager.lastLoopDate,
            minPredBG: nil,
            simulatedCOB: nil,
            isBackdated: false
        )
        return (apsManager.roundBolus(amount: result.insulinCalculated), glucoseStorage.lastGlucoseDate())
    }

    func logCarbs(_ carbs: Decimal) async throws {
        let now = Date()
        try await carbsStorage.storeCarbs(
            [CarbsEntry(
                id: UUID().uuidString, createdAt: now, actualDate: now,
                carbs: carbs, fat: 0, protein: 0, note: "Via Meal",
                enteredBy: CarbsEntry.local, isFPU: false, fpuID: nil
            )],
            areFetchedFromRemote: false
        )
    }

    /// BolusIntentRequest.bolus's steps (same setting check, validator, rounding and enact call), returning
    /// whether the bolus was sent so a refusal is never mistaken for a delivery.
    func bolus(_ units: Decimal) async throws -> QuickMeal.BolusOutcome {
        guard settingsManager.settings.bolusShortcut == .limitWithSafetyChecks else {
            let reason = String(localized: "bolus via Shortcuts is off in settings.")
            return QuickMeal.BolusOutcome(sent: false, message: String(localized: "Bolus not sent: ") + reason, reason: reason)
        }
        let requestedAmount = units
        let validation = try await bolusSafetyValidator.validate(bolusAmount: requestedAmount)

        if case let .rejected(reason) = validation {
            let text = reason.mealShortcutMessage(
                requestedAmount: requestedAmount,
                pumpMaxBolus: settingsManager.pumpSettings.maxBolus
            )
            return QuickMeal.BolusOutcome(sent: false, message: String(localized: "Bolus not sent: ") + text, reason: text)
        }

        let bolusQuantity = apsManager.roundBolus(amount: requestedAmount)
        // Deliberate departure from upstream BolusIntentRequest, which passes `callback: nil` and reports
        // success whatever the pump did. Do not re-sync this with upstream on merges.
        // enactBolus reports failure (pump suspended or bolusing, no pump, pump error) only through this
        // callback, and calls it before it returns on every path except `amount <= 0`. No callback, or a
        // pump error (delivery uncertain), means we cannot say either way: never "sent" without a success
        // callback, and "not sent" only for enactBolus's pre-pump refusal.
        var enacted: (success: Bool, message: String)?
        await apsManager.enactBolus(amount: Double(bolusQuantity), isSMB: false) { success, message in
            enacted = (success, message)
        }
        guard let enacted else { return QuickMeal.BolusOutcome.unknown }
        guard enacted.success else { return QuickMeal.BolusOutcome.outcomeForFailedEnact(message: enacted.message) }
        return QuickMeal.BolusOutcome(
            sent: true, message: String(localized: "Bolus \(bolusQuantity.formatted()) U sent."), reason: nil
        )
    }
}

/// Copy of BolusIntentRequest.swift's private `shortcutMessage` (private there; that upstream file is left unedited).
private extension BolusSafetyRejection {
    func mealShortcutMessage(requestedAmount: Decimal, pumpMaxBolus: Decimal) -> String {
        switch self {
        case .exceedsMaxBolus:
            return String(
                localized:
                "The bolus cannot be larger than the pump setting max bolus (\(pumpMaxBolus.description))."
            )
        case .iobUnavailable:
            return String(
                localized:
                "Bolus blocked: current IOB is not available."
            )
        case let .exceedsMaxIOB(currentIOB, maxIOB):
            return String(
                localized:
                "Bolus blocked: a \(requestedAmount.formatted()) U bolus would exceed max IOB (\(maxIOB.formatted()) U). Current IOB: \(currentIOB.formatted()) U."
            )
        case .recentBolusWithinWindow:
            return String(
                localized:
                "Bolus blocked: a significant bolus was delivered within the last \(BolusSafetyEvaluator.recentBolusWindowMinutes) minutes."
            )
        }
    }
}
