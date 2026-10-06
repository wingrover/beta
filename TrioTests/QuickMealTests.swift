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

    @Test func externalInsulinNeverFollows() {
        let state = Treatments.StateModel()
        state.externalInsulin = true
        state.insulinCalculated = 4.2
        state.applyFollow(glucoseDate: now.addingTimeInterval(-60), now: now)
        #expect(state.amount == 0)
    }

    @Test func tickingExternalClearsFollowedValue() {
        let state = Treatments.StateModel()
        state.insulinCalculated = 4.2
        state.applyFollow(glucoseDate: now.addingTimeInterval(-60), now: now)
        #expect(state.amount == 4.2)
        state.externalInsulin = true
        #expect(state.amount == 0)
    }

    @Test func tickingExternalKeepsTypedValue() {
        let state = Treatments.StateModel()
        state.amount = 2
        state.userEditedBolus = true
        state.externalInsulin = true
        #expect(state.amount == 2)
    }

    @Test func freezeReturnsTappedAmountAndStopsFollowing() {
        let state = Treatments.StateModel()
        state.insulinCalculated = 4.2
        state.applyFollow(glucoseDate: now.addingTimeInterval(-60), now: now)
        let tapped = state.freezeBolusForSubmit()
        #expect(tapped == 4.2)
        #expect(state.userEditedBolus)
        state.insulinCalculated = 6.0
        state.applyFollow(glucoseDate: now.addingTimeInterval(-60), now: now)
        #expect(state.amount == 4.2)
    }
}

@Suite("Quick Meal store") struct QuickMealStoreTests {
    @Test func roundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "QuickMealStoreTests"))
        defaults.removePersistentDomain(forName: "QuickMealStoreTests")
        let store = try #require(QuickMeal.Store(defaults: defaults))
        let snap = QuickMeal.Snapshot(bg: "7.8", direction: "↗", glucoseDate: Date(timeIntervalSince1970: 5), iob: 1.2, cob: 20)
        store.snapshot = snap
        store.pending = QuickMeal.Pending(carbs: 30, units: 3.1, createdAt: Date(timeIntervalSince1970: 9))
        #expect(store.snapshot == snap)
        #expect(store.pending?.units == 3.1)
        store.pending = nil
        #expect(store.pending == nil)
    }

    @Test func claimPendingClaimsOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "QuickMealStoreClaimTests"))
        defaults.removePersistentDomain(forName: "QuickMealStoreClaimTests")
        let store = try #require(QuickMeal.Store(defaults: defaults))
        let pending = QuickMeal.Pending(carbs: 30, units: 3.1, createdAt: Date(timeIntervalSince1970: 9))
        store.pending = pending
        #expect(store.claimPending() == pending)
        #expect(store.claimPending() == nil)
        #expect(store.pending == nil)
    }

    @Test func lastOutcomeRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "QuickMealStoreOutcomeTests"))
        defaults.removePersistentDomain(forName: "QuickMealStoreOutcomeTests")
        let store = try #require(QuickMeal.Store(defaults: defaults))
        let outcome = QuickMeal.Outcome(message: "Logged 30 g. Bolus 3.1 U sent.", date: Date(timeIntervalSince1970: 9))
        store.lastOutcome = outcome
        #expect(store.lastOutcome == outcome)
        store.lastOutcome = nil
        #expect(store.lastOutcome == nil)
    }

    @Test func outcomeWarnings() {
        let date = Date(timeIntervalSince1970: 9)
        #expect(!QuickMeal.Outcome(message: "Logged 30 g. Bolus 3.1 U sent.", date: date).isWarning)
        #expect(!QuickMeal.Outcome(message: "Logged 30 g. No bolus.", date: date).isWarning)
        #expect(QuickMeal.Outcome(message: "Logged 30 g. Bolus NOT given: blocked", date: date).isWarning)
        #expect(QuickMeal.Outcome(message: "Not logged: glucose is over 15 min old", date: date).isWarning)
        #expect(QuickMeal.Outcome(message: "Nothing logged: offline", date: date).isWarning)
    }

    /// Pending units go through JSON and are later compared with `!=` to a fresh Decimal in confirmCheck;
    /// a lossy decode would make the widget's Confirm return .changed forever.
    @Test(arguments: [Decimal(string: "0.05")!, Decimal(string: "3.15")!, Decimal(string: "12.35")!])
    func pendingUnitsSurviveStorage(units: Decimal) throws {
        // One suite per case: parameterised cases run in parallel.
        let suite = "QuickMealStoreDecimalTests.\(units)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = try #require(QuickMeal.Store(defaults: defaults))
        let now = Date(timeIntervalSince1970: 1_000_000)
        store.pending = QuickMeal.Pending(carbs: 30, units: units, createdAt: now.addingTimeInterval(-10))
        let readBack = try #require(store.pending)
        #expect(readBack.units == units)
        #expect(QuickMeal.confirmCheck(pending: readBack, freshUnits: units, glucoseDate: now.addingTimeInterval(-10), now: now)
            == .go)
    }
}
