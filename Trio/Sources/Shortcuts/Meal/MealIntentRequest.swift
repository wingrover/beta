import CoreData
import Foundation

/// Shared by the Meal Shortcut and the Meal widget: works out the dose, logs carbs, sends the bolus
/// through the same safety-checked path as the "Enact Bolus" Shortcut.
final class MealIntentRequest: BaseIntentsRequest {
    private lazy var calculator = TrioApp.resolver.resolve(BolusCalculationManager.self)!
    private lazy var determinationStorage = TrioApp.resolver.resolve(DeterminationStorage.self)!

    var bolusAllowed: Bool { settingsManager.settings.bolusShortcut == .limitWithSafetyChecks }

    func recommendation(carbs: Decimal) async -> (units: Decimal, glucoseDate: Date?) {
        // Same fetch as the Apple Watch recommendation: the calculator zeroes the bolus when minPredBG < 54,
        // so it must see the last determination's value (54 when there is none).
        var minPredBG: Decimal = 54
        do {
            let context = CoreDataStack.shared.newTaskContext()
            context.name = "mealIntentRecommendation"
            let determinationIds = try await determinationStorage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            )
            let determinationObjects: [OrefDetermination] = try await CoreDataStack.shared.getNSManagedObject(
                with: determinationIds,
                context: context
            )
            minPredBG = await context.perform { determinationObjects.first?.minPredBGFromReason ?? 54 }
        } catch {
            debug(.default, "Meal recommendation: could not read minPredBG, using 54: \(error)")
        }

        let result = await calculator.handleBolusCalculation(
            carbs: carbs,
            useFattyMealCorrection: false,
            useSuperBolus: false,
            lastLoopDate: apsManager.lastLoopDate,
            minPredBG: minPredBG,
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
