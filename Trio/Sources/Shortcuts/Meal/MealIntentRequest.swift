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

    func bolus(_ units: Decimal) async throws -> String {
        try await BolusIntentRequest().bolus(Double(truncating: units as NSNumber))
    }
}
