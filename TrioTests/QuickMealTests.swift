import Foundation
import Testing
@testable import Trio

@Suite("Quick Meal rules") struct QuickMealTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    @Test func freshAtBoundary() { #expect(QuickMeal.isGlucoseFresh(ago(15 * 60), now: now)) }
    @Test func staleJustOver() { #expect(!QuickMeal.isGlucoseFresh(ago(15 * 60 + 1), now: now)) }
    @Test func missingGlucoseIsStale() { #expect(!QuickMeal.isGlucoseFresh(nil, now: now)) }

    @Test func followsRecommendation() {
        #expect(QuickMeal.followedBolus(recommended: 4.2, glucoseDate: ago(60), now: now, userEdited: false) == 4.2)
    }
    @Test func userEditStopsFollowing() {
        #expect(QuickMeal.followedBolus(recommended: 4.2, glucoseDate: ago(60), now: now, userEdited: true) == nil)
    }
    @Test func staleFollowsToZero() {
        #expect(QuickMeal.followedBolus(recommended: 4.2, glucoseDate: ago(16 * 60), now: now, userEdited: false) == 0)
    }
    @Test func negativeRecommendationIsZero() {
        #expect(QuickMeal.followedBolus(recommended: -1, glucoseDate: ago(60), now: now, userEdited: false) == 0)
    }

    @Test func decideStale() {
        #expect(QuickMeal.decide(carbs: 40, recommended: 4, glucoseDate: ago(20 * 60), now: now, bolusAllowed: true) == .stale)
    }
    @Test func decideZeroRecommended() {
        #expect(QuickMeal.decide(carbs: 40, recommended: 0, glucoseDate: ago(60), now: now, bolusAllowed: true)
            == .carbsOnly(carbs: 40, bolusDisabled: false))
    }
    @Test func bolusDisabledLogsCarbsOnly() {
        #expect(QuickMeal.decide(carbs: 40, recommended: 4, glucoseDate: ago(60), now: now, bolusAllowed: false)
            == .carbsOnly(carbs: 40, bolusDisabled: true))
    }
    @Test func decideBoth() {
        #expect(QuickMeal.decide(carbs: 40, recommended: 4.2, glucoseDate: ago(60), now: now, bolusAllowed: true)
            == .carbsAndBolus(carbs: 40, units: 4.2))
    }

    func pending(age: TimeInterval, units: Decimal = 3.1) -> QuickMeal.Pending {
        QuickMeal.Pending(carbs: 30, units: units, createdAt: ago(age))
    }
    @Test func confirmGo() {
        #expect(QuickMeal.confirmCheck(pending: pending(age: 10), freshUnits: 3.1, glucoseDate: ago(60), now: now) == .go)
    }
    @Test func confirmExpired() {
        #expect(QuickMeal.confirmCheck(pending: pending(age: 61), freshUnits: 3.1, glucoseDate: ago(60), now: now) == .expired)
    }
    @Test func confirmStale() {
        #expect(QuickMeal.confirmCheck(pending: pending(age: 10), freshUnits: 3.1, glucoseDate: ago(16 * 60), now: now) == .stale)
    }
    @Test func confirmUnitsChanged() {
        #expect(QuickMeal.confirmCheck(pending: pending(age: 10), freshUnits: 2.9, glucoseDate: ago(60), now: now)
            == .changed(units: 2.9))
    }

    @Test func labels() {
        #expect(QuickMeal.screenLabel(carbs: 40, units: 4.2) == "Log 40 g + bolus 4.2 U")
        #expect(QuickMeal.screenLabel(carbs: 40, units: 0) == "Log 40 g")
        #expect(QuickMeal.screenLabel(carbs: 0, units: 4.2) == "Bolus 4.2 U")
        #expect(QuickMeal.screenLabel(carbs: 0, units: 0) == nil)
    }
}

@Suite("Quick Meal screen follow") struct QuickMealScreenTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func followsWhenFresh() {
        let state = Treatments.StateModel()
        state.insulinCalculated = 4.2
        state.applyFollow(glucoseDate: now.addingTimeInterval(-60), now: now)
        #expect(state.amount == 4.2)
        #expect(!state.followBlockedByStaleGlucose)
    }

    @Test func userEditStopsFollowing() {
        let state = Treatments.StateModel()
        state.amount = 2
        state.userEditedBolus = true
        state.insulinCalculated = 4.2
        state.applyFollow(glucoseDate: now.addingTimeInterval(-60), now: now)
        #expect(state.amount == 2)
    }

    @Test func staleSetsZeroAndFlag() {
        let state = Treatments.StateModel()
        state.insulinCalculated = 4.2
        state.applyFollow(glucoseDate: now.addingTimeInterval(-16 * 60), now: now)
        #expect(state.amount == 0)
        #expect(state.followBlockedByStaleGlucose)
    }
}
