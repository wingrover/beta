# Quick Meal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three quick ways to log a meal and give Trio's recommended bolus with one confirm: a Meal button on the Live Activity, a Meal Shortcut, and a home-screen Meal widget with preset carbs.

**Architecture:** One pure Foundation file, `Trio/Sources/Models/QuickMeal.swift`, holds every rule (freshness, follow, decide, confirm re-check, labels) plus the app-group store; it is compiled into both the app and the `LiveActivityExtension` target. The meal screen, the Shortcut and the widget intents call those rules; dosing always goes through existing Trio paths (`UnlockManager` + `APSManager.enactBolus` on screen, `BolusIntentRequest.bolus` from Shortcut and widget). Widget intents are `LiveActivityIntent`s defined in one file shared by both targets; their bodies are compiled only in the app (`#if !WIDGET_EXTENSION`), so iOS runs them in Beta's process.

**Tech Stack:** Swift 6 / SwiftUI, App Intents, WidgetKit + ActivityKit, Swinject DI, Swift Testing (`@Suite`, `@Test`, `#expect`), Xcode project file edited by hand, GitHub Actions (macOS 26 runner, Xcode 26.2).

**Spec:** `docs/plans/2026-10-06-quick-meal-design.md` (ticked by Ben 2026-10-06). Read it before any task.

## Global Constraints

- Repo `~/dev/beta`, branch `quick-meal`, remote `origin` = `git@github.com:wingrover/beta.git`. Every commit lands on `quick-meal`; check `git branch --show-current` before committing. Never commit to `beta`, `dev` or `main`.
- **The box cannot build iOS.** There is no Xcode, `swift` or `xcodebuild` here. The only compiler and test runner is GitHub Actions: `gh workflow run unit_tests.yml -R wingrover/beta --ref quick-meal`, then `gh run watch <id> -R wingrover/beta --exit-status`. One run takes about 20 minutes. "Run the test" in every task means this.
- **Adding a Swift file to a target means editing `Trio.xcodeproj/project.pbxproj`** (Task 0 explains how), except files under `LiveActivity/Views/`, which is a synchronized folder and joins the `LiveActivityExtension` target automatically.
- Stale glucose = latest reading older than **15 minutes** (`QuickMeal.maxGlucoseAge = 15 * 60`); exactly 15 min is still fresh.
- Widget confirm lifetime = **60 seconds** (`QuickMeal.pendingLifetime = 60`).
- Widget presets fixed at **15, 30, 45, 60 g**; family `.systemMedium` only.
- Labels, exactly: `Log 40 g + bolus 4.2 U`, `Log 40 g`, `Bolus 4.2 U` (screen); `Log 40 g and bolus 4.2 U?`, `Log 40 g? (no bolus recommended)` (Shortcut); `30 g → bolus 3.1 U`, `30 g, no bolus` (widget). Stale note: `Glucose is over 15 min old: enter the bolus yourself`.
- No change to the dosing algorithm, SMB, the calculator's maths, max bolus or `BolusSafetyValidator`.
- Swift style: match surrounding code (4-space indent, `String(localized:)` for user-facing text). SwiftFormat runs in CI; keep lines under 130 chars.
- Never `--no-verify`. A red CI run is a finding: read the log (`gh run view <id> -R wingrover/beta --log-failed | grep -E "error:|✘|failed"`), form one hypothesis, fix.

## Review Focus

1. Hand-edited bolus, then carbs changed: the bolus must stay where the user put it (Task 2 test `userEditStopsFollowing`).
2. Glucose exactly 15:00 old is fresh, 15:01 is stale (Task 1 tests `freshAtBoundary`, `staleJustOver`).
3. The recommendation changes between the widget tap and Confirm: nothing is dosed, the card asks again with the new units (Task 1 test `confirmUnitsChanged`).
4. Face ID cancelled on the meal screen with a bolus entered: nothing is saved, not even carbs (Task 2 reorders `invokeTreatmentsTask`; reviewer reads it; Ben's check 2 backs it).
5. Shortcut bolus setting off: carbs are logged and the reply says the bolus was not sent; no bolus call is made (Task 1 test `bolusDisabledLogsCarbsOnly`; Task 4 routes on it).

---

### Task 0: Run the unit tests on the fork

**Files:**
- Modify: `.github/workflows/unit_tests.yml`

- [ ] **Step 1:** Under `on:` add `workflow_dispatch:` (no inputs).
- [ ] **Step 2:** Change both job conditions `if: github.repository_owner == 'nightscout'` (jobs `algorithm-package` and `test`) to `if: github.repository_owner == 'nightscout' || github.repository_owner == 'wingrover'`.
- [ ] **Step 3:** Commit `ci: allow unit tests to run on the wingrover fork` and push.
- [ ] **Step 4:** `gh workflow run unit_tests.yml -R wingrover/beta --ref quick-meal`, watch it. Expected: both jobs green on the untouched code. This is the baseline; if it is red, stop and report the failing tests (they are upstream's, not ours).

**How to add a Swift file to the Xcode project (used by Tasks 1, 3, 4, 5):** for each new file add
1. a `PBXFileReference` line (copy `AddCarbPresetIntent.swift`'s at ~line 1765, new 24-char uppercase hex id),
2. a `PBXBuildFile` line per target it compiles in (copy line ~678; new id each, `fileRef` = the file reference id),
3. the file reference id in its folder's `PBXGroup` `children` (create the group if the folder is new and add it to the parent group's children, as `Carbs` sits in `Shortcuts` at ~line 4041),
4. the build file id in the target's `PBXSourcesBuildPhase`: app `388E595425AD948C0019842D`, tests `38FCF3E925E9028E0078B0D1`, LiveActivity `6B1A8D132B14D91500E76752`.
Generate ids with `python3 -c "import secrets;print(secrets.token_hex(12).upper())"` and `grep` each one to prove it is unused. `LiveActitiyAttributes.swift` (file ref `6BCF84DC2B16843A003AD46E`) is the example of one file in two targets.

---

### Task 1: The rules (`QuickMeal.swift`) and their tests

**Files:**
- Create: `Trio/Sources/Models/QuickMeal.swift` (app target now; Task 5 adds it to LiveActivity)
- Test: `TrioTests/QuickMealTests.swift` (TrioTests target)
- Modify: `Trio.xcodeproj/project.pbxproj`

**Interfaces — Produces:**
```swift
enum QuickMeal {
    static let maxGlucoseAge: TimeInterval            // 900
    static let pendingLifetime: TimeInterval          // 60
    static let presets: [Int]                         // [15, 30, 45, 60]
    static func isGlucoseFresh(_ date: Date?, now: Date) -> Bool
    static func followedBolus(recommended: Decimal, glucoseDate: Date?, now: Date, userEdited: Bool) -> Decimal?
    static func decide(carbs: Decimal, recommended: Decimal, glucoseDate: Date?, now: Date, bolusAllowed: Bool) -> Decision
    static func confirmCheck(pending: Pending, freshUnits: Decimal, glucoseDate: Date?, now: Date) -> ConfirmOutcome
    static func screenLabel(carbs: Decimal, units: Decimal) -> String?
    enum Decision: Equatable { case stale; case carbsOnly(carbs: Decimal, bolusDisabled: Bool); case carbsAndBolus(carbs: Decimal, units: Decimal) }
    enum ConfirmOutcome: Equatable { case go; case expired; case stale; case changed(units: Decimal) }
    struct Pending: Codable, Equatable { var carbs: Decimal; var units: Decimal; var createdAt: Date }
}
```

- [ ] **Step 1: Write the failing tests** in `TrioTests/QuickMealTests.swift`:

```swift
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
```

- [ ] **Step 2: Implement** `Trio/Sources/Models/QuickMeal.swift`:

```swift
import Foundation

/// Rules shared by the meal screen, the Meal Shortcut and the Meal widget (spec 2026-10-06-quick-meal-design.md).
/// Pure Foundation: this file is compiled into both the app and the LiveActivity widget extension.
enum QuickMeal {
    static let maxGlucoseAge: TimeInterval = 15 * 60
    static let pendingLifetime: TimeInterval = 60
    static let presets = [15, 30, 45, 60]

    static func isGlucoseFresh(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) <= maxGlucoseAge
    }

    /// The bolus the meal screen should show, or nil when the user has typed their own and it must be left alone.
    static func followedBolus(recommended: Decimal, glucoseDate: Date?, now: Date, userEdited: Bool) -> Decimal? {
        if userEdited { return nil }
        guard isGlucoseFresh(glucoseDate, now: now) else { return 0 }
        return max(recommended, 0)
    }

    enum Decision: Equatable {
        case stale
        case carbsOnly(carbs: Decimal, bolusDisabled: Bool)
        case carbsAndBolus(carbs: Decimal, units: Decimal)
    }

    static func decide(carbs: Decimal, recommended: Decimal, glucoseDate: Date?, now: Date, bolusAllowed: Bool) -> Decision {
        guard isGlucoseFresh(glucoseDate, now: now) else { return .stale }
        guard recommended > 0 else { return .carbsOnly(carbs: carbs, bolusDisabled: false) }
        guard bolusAllowed else { return .carbsOnly(carbs: carbs, bolusDisabled: true) }
        return .carbsAndBolus(carbs: carbs, units: recommended)
    }

    struct Pending: Codable, Equatable {
        var carbs: Decimal
        var units: Decimal
        var createdAt: Date
    }

    enum ConfirmOutcome: Equatable {
        case go
        case expired
        case stale
        case changed(units: Decimal)
    }

    static func confirmCheck(pending: Pending, freshUnits: Decimal, glucoseDate: Date?, now: Date) -> ConfirmOutcome {
        if now.timeIntervalSince(pending.createdAt) > pendingLifetime { return .expired }
        guard isGlucoseFresh(glucoseDate, now: now) else { return .stale }
        if freshUnits != pending.units { return .changed(units: freshUnits) }
        return .go
    }

    static func screenLabel(carbs: Decimal, units: Decimal) -> String? {
        switch (carbs > 0, units > 0) {
        case (true, true): return String(localized: "Log \(carbs.formatted()) g + bolus \(units.formatted()) U")
        case (true, false): return String(localized: "Log \(carbs.formatted()) g")
        case (false, true): return String(localized: "Bolus \(units.formatted()) U")
        case (false, false): return nil
        }
    }
}
```

- [ ] **Step 3:** Add `QuickMeal.swift` to the app target (group `Models`, Sources phase `388E595425AD948C0019842D`) and `QuickMealTests.swift` to TrioTests (group `38FCF3EE25E9028E0078B0D1`, phase `38FCF3E925E9028E0078B0D1`), per Task 0's recipe.
- [ ] **Step 4:** Commit `quick meal: rules and tests`, push, run CI. Expected: green, `Quick Meal rules` suite listed with 16 passing tests (`gh run view <id> --log | grep -i "quick meal"`). If the label test fails on number formatting (`4.2` vs locale), fix the test's expectation only if CI's locale is the cause, and say so in the commit.

---

### Task 2: Meal screen follows the recommendation; Face ID first

**Files:**
- Modify: `Trio/Sources/Modules/Treatments/TreatmentsStateModel.swift` (`insulinCalculated` ~line 65, `cleanupTreatmentState` ~231, `invokeTreatmentsTask` ~496, `addPumpInsulin` ~632)
- Modify: `Trio/Sources/Modules/Treatments/View/TreatmentsRootView.swift` (bolus field ~367-388, `taskButtonLabel` ~640-679, `onAppear` ~433)
- Test: `TrioTests/QuickMealTests.swift` (append a second suite)

**Interfaces — Consumes:** `QuickMeal.followedBolus`, `QuickMeal.isGlucoseFresh`, `QuickMeal.screenLabel` (Task 1). **Produces:** `Treatments.StateModel.userEditedBolus: Bool`, `followBlockedByStaleGlucose: Bool`, `applyFollow(glucoseDate: Date?, now: Date)`.

- [ ] **Step 1: Failing tests**, appended to `TrioTests/QuickMealTests.swift` (pattern from `AlgorithmSuggestedBolusTests`: a bare `Treatments.StateModel()`):

```swift
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
```

- [ ] **Step 2: State model.** Add beside `insulinCalculated`:

```swift
        var insulinCalculated: Decimal = 0 {
            didSet { applyFollow(glucoseDate: latestGlucose?.date, now: Date()) }
        }

        /// Quick Meal: true once the user types in the bolus field; the field then stops following the recommendation.
        var userEditedBolus = false
        /// Quick Meal: true when glucose is over 15 min old, so the bolus was not filled in.
        var followBlockedByStaleGlucose = false

        func applyFollow(glucoseDate: Date?, now: Date) {
            followBlockedByStaleGlucose = !QuickMeal.isGlucoseFresh(glucoseDate, now: now)
            if let followed = QuickMeal.followedBolus(
                recommended: insulinCalculated, glucoseDate: glucoseDate, now: now, userEdited: userEditedBolus
            ) {
                amount = followed
            }
        }
```

If `@Observable` rejects `didSet` on that property, put the `applyFollow` call at the end of the two writers instead: `scheduleInsulinAndForecastUpdate()` after `self.insulinCalculated = insulinCalculated`, and the view's `handleDebouncedInput()` plus the other four `state.insulinCalculated = await state.calculateInsulin()` sites — every writer, none missed (`grep -n "insulinCalculated =" Trio/Sources/Modules/Treatments`).

In `cleanupTreatmentState()` add `userEditedBolus = false` and `followBlockedByStaleGlucose = false`.

- [ ] **Step 3: Face ID before anything is saved.** In `invokeTreatmentsTask()`, when `amount > 0 && !externalInsulin`, authenticate first and stop if refused, so a cancelled Face ID saves no carbs:

```swift
            if amount > 0, !externalInsulin {
                let authenticated = (try? await unlockmanager.unlock()) ?? false
                guard authenticated else {
                    await MainActor.run { addButtonPressed = false }
                    return
                }
            }
```

placed before the `saveMeal()` call. Then `addPumpInsulin()` must not ask again: give it a parameter `alreadyAuthenticated: Bool = false` and skip its `unlockmanager.unlock()` when true; `handleInsulin(isExternal:)` passes `alreadyAuthenticated: true` on this path. Keep the existing `catch` that sets `showDeterminationFailureAlert` for the unlock error case (move the `do/catch` so a thrown unlock error still shows the alert instead of `try?` swallowing it, if the existing alert text matters — it does: use `do { guard try await unlockmanager.unlock() else {...} } catch { showDeterminationFailureAlert = true; determinationFailureMessage = parseAuthenticationError(error); addButtonPressed = false; return }`, matching the names already in `addPumpInsulin`).

- [ ] **Step 4: View.**
  - Bolus field: in its `.onChange(of: state.amount)`, add `if focusedField == .bolus { state.userEditedBolus = true }` before the existing `Task`.
  - Under the bolus field, when `state.followBlockedByStaleGlucose && state.carbs > 0`, show `Text(String(localized: "Glucose is over 15 min old: enter the bolus yourself")).font(.footnote).foregroundStyle(.orange)`.
  - `taskButtonLabel`: before the existing `switch`, when `!state.externalInsulin` and fat and protein are both 0, `if let label = QuickMeal.screenLabel(carbs: state.carbs, units: state.amount) { return Text(label) }` (match the property's return type; the limit-exceeded texts keep priority, so put this after them).
  - Focus carbs when the screen opens: at the end of the `onAppear` block, `DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focusedField = .carbs }` (the delay lets the sheet finish presenting; the unused `autofocus` property stays as it is).
- [ ] **Step 5:** Commit `quick meal: screen follows the recommendation, Face ID before saving`, push, CI. Expected: green, 3 new tests pass.

---

### Task 3: `Trio://meal`, the Live Activity Meal button

**Files:**
- Modify: `Trio/Sources/Application/TrioApp.swift` (`handleURL`, ~line 532)
- Create: `Trio/Sources/Shortcuts/Meal/MealWidgetIntents.swift` (app target now; Task 5 adds LiveActivity)
- Modify: `LiveActivity/Views/LiveActivityView.swift` (iOS branches 3 and 4 of `body`; expanded bottom view ~179-221)
- Modify: `Trio.xcodeproj/project.pbxproj` (new `Meal` group under `Shortcuts`, the new file; and `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for the LiveActivity target's Debug and Release configs: `"WIDGET_EXTENSION $(inherited)"`, keeping `DEBUG` where present)

**Interfaces — Produces:** `struct OpenMealIntent: LiveActivityIntent` (`openAppWhenRun = true`), and the file `MealWidgetIntents.swift` that Task 6 extends.

- [ ] **Step 1: Route.** In `handleURL`, add `case "meal": resolver.resolve(Router.self)!.mainModalScreen.send(.treatmentView)`.
- [ ] **Step 2: Intent file** `Trio/Sources/Shortcuts/Meal/MealWidgetIntents.swift`:

```swift
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
```

(Check `TrioApp.resolver` is the static used by `BaseIntentsRequest.init`; use the same expression.)
- [ ] **Step 3: Button.** In `LiveActivityView`, iOS detailed branch (3) and simple branch (4) only — never the watchOS branches — add trailing in the HStack:

```swift
Button(intent: OpenMealIntent()) {
    Label(String(localized: "Meal"), systemImage: "fork.knife")
        .font(.footnote.weight(.semibold))
}
.buttonStyle(.bordered)
.tint(.green)
```

and the same button in `LiveActivityExpandedBottomView`, under its existing content.
- [ ] **Step 4:** pbxproj: new group, file in app Sources and LiveActivity Sources (two build files, one file ref), `WIDGET_EXTENSION` condition on LiveActivity configs (find them via the target `6B1A8D162B14D91500E76752`'s `buildConfigurationList`).
- [ ] **Step 5:** Commit `quick meal: Meal button on the Live Activity, Trio://meal route`, push, CI. Expected: green (this proves the shared-file + compile-condition pattern builds in both targets before Task 6 leans on it).

---

### Task 4: The Meal Shortcut

**Files:**
- Create: `Trio/Sources/Shortcuts/Meal/MealIntentRequest.swift`, `Trio/Sources/Shortcuts/Meal/MealIntent.swift` (app target)
- Modify: `Trio/Sources/Shortcuts/AppShortcuts.swift`, `Trio.xcodeproj/project.pbxproj`

**Interfaces — Consumes:** `QuickMeal.decide`, `BolusIntentRequest.bolus(_:)`, `BolusCalculationManager.handleBolusCalculation(...)`, `GlucoseStorage.lastGlucoseDate()`, `CarbsStorage.storeCarbs(_:areFetchedFromRemote:)`. **Produces** (used by Task 6):

```swift
final class MealIntentRequest: BaseIntentsRequest {
    var bolusAllowed: Bool
    func recommendation(carbs: Decimal) async -> (units: Decimal, glucoseDate: Date?)
    func logCarbs(_ carbs: Decimal) async throws
    func bolus(_ units: Decimal) async throws -> String
}
```

- [ ] **Step 1: Request** `MealIntentRequest.swift`:

```swift
import Foundation

/// Shared by the Meal Shortcut and the Meal widget: works out the dose, logs carbs, sends the bolus
/// through the same safety-checked path as the "Enact Bolus" Shortcut.
final class MealIntentRequest: BaseIntentsRequest {
    private lazy var calculator = TrioApp.resolver.resolve(BolusCalculationManager.self)!

    var bolusAllowed: Bool { settingsManager.settings.bolusShortcut == .limitWithSafetyChecks }

    func recommendation(carbs: Decimal) async -> (units: Decimal, glucoseDate: Date?) {
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
```

`minPredBG: nil` — check `AppleWatchManager.swift:~745-761`: if it fetches `minPredBG` from the last determination, copy that fetch here instead of `nil` so the low-prediction zeroing still applies. That fetch is required, not optional: the calculator's `minPredBG < 54` guard is a safety rule.

- [ ] **Step 2: Intent** `MealIntent.swift`:

```swift
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
```

- [ ] **Step 3:** `AppShortcuts.swift`: add

```swift
        AppShortcut(
            intent: MealIntent(),
            phrases: ["\(.applicationName) meal", "Log a meal in \(.applicationName)"],
            shortTitle: "Meal",
            systemImageName: "fork.knife"
        )
```

- [ ] **Step 4:** pbxproj: both files in the `Meal` group, app Sources only.
- [ ] **Step 5:** Commit `quick meal: Meal Shortcut`, push, CI green. (The intent's branching is `QuickMeal.decide`, already tested in Task 1; the intent itself is glue.)

---

### Task 5: Widget plumbing — app group for the extension, snapshot writer

**Files:**
- Create: `LiveActivity/LiveActivity.entitlements`
- Modify: `LiveActivity/Info.plist`, `fastlane/Fastfile:198`, `Trio.xcodeproj/project.pbxproj`, `Trio/Sources/Models/QuickMeal.swift`, `Trio/Sources/Services/LiveActivity/LiveActivityManager.swift`
- Test: `TrioTests/QuickMealTests.swift`

**Interfaces — Produces:**
```swift
extension QuickMeal {
    struct Snapshot: Codable, Equatable { var bg: String; var direction: String?; var glucoseDate: Date?; var iob: Decimal; var cob: Decimal }
    struct Store { init?(defaults: UserDefaults?); var snapshot: Snapshot? { get nonmutating set }; var pending: Pending? { get nonmutating set } }
    static var sharedStore: Store?   // app-group UserDefaults from the AppGroupID Info.plist key
    static let widgetKind: String    // "MealWidget"
}
```

- [ ] **Step 1: Failing test** (round trip through a throwaway suite):

```swift
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
}
```

- [ ] **Step 2: Implement** (append to `QuickMeal.swift`):

```swift
extension QuickMeal {
    static let widgetKind = "MealWidget"

    struct Snapshot: Codable, Equatable {
        var bg: String
        var direction: String?
        var glucoseDate: Date?
        var iob: Decimal
        var cob: Decimal
    }

    /// Small JSON values in the app-group UserDefaults, read by the widget and written by the app.
    struct Store {
        let defaults: UserDefaults
        init?(defaults: UserDefaults?) {
            guard let defaults else { return nil }
            self.defaults = defaults
        }

        var snapshot: Snapshot? {
            get { read("quickMeal.snapshot") }
            nonmutating set { write(newValue, "quickMeal.snapshot") }
        }

        var pending: Pending? {
            get { read("quickMeal.pending") }
            nonmutating set { write(newValue, "quickMeal.pending") }
        }

        private func read<T: Decodable>(_ key: String) -> T? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }

        private func write<T: Encodable>(_ value: T?, _ key: String) {
            if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }

    static var sharedStore: Store? {
        let suite = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String
        return Store(defaults: suite.flatMap { UserDefaults(suiteName: $0) })
    }
}
```

- [ ] **Step 3: Extension gets the app group.**
  - `LiveActivity/LiveActivity.entitlements`: a plist with `com.apple.security.application-groups` = array containing `$(APP_GROUP_ID)` (copy `Trio/Resources/Trio.entitlements`' key, nothing else).
  - `LiveActivity/Info.plist`: add `<key>AppGroupID</key><string>$(APP_GROUP_ID)</string>`.
  - pbxproj, LiveActivity Debug and Release configs: `APP_GROUP_ID = "$(TRIO_APP_GROUP_ID)";` and `CODE_SIGN_ENTITLEMENTS = LiveActivity/LiveActivity.entitlements;`; file reference for the entitlements file in the `LiveActivity` group (no build file). Add `QuickMeal.swift` to LiveActivity Sources (second build file, same file ref).
  - `fastlane/Fastfile:198`: `configure_bundle_id("Trio LiveActivity", "#{BUNDLE_ID}.LiveActivity", [Spaceship::ConnectAPI::BundleIdCapability::Type::APP_GROUPS])`.
- [ ] **Step 4: Snapshot writer.** In `LiveActivityManager.pushCurrentContent()` (line ~403) right after `content` (the `ContentState`) is built, and in the other `ContentState(` site (~294) likewise, write:

```swift
        QuickMeal.sharedStore?.snapshot = QuickMeal.Snapshot(
            bg: content.bg, direction: content.direction, glucoseDate: content.date,
            iob: content.detailedViewState.iob, cob: content.detailedViewState.cob
        )
        WidgetCenter.shared.reloadTimelines(ofKind: QuickMeal.widgetKind)
```

(`import WidgetKit` at the top of the file.) If `pushCurrentContent` returns early when the user has the Live Activity switched off, also write the snapshot before that early return — find where the data is fetched and write it there instead; the widget must not depend on the Live Activity setting. Read the function and choose the one spot every update passes through; state it in the commit message.
- [ ] **Step 5:** Commit `quick meal: app group for the widget extension, snapshot writer`, push, CI green (store test passes; extension builds with entitlements under ad-hoc signing).

---

### Task 6: The Meal widget and its intents

**Files:**
- Create: `LiveActivity/Views/MealWidget.swift` (synchronized folder: no pbxproj edit)
- Modify: `LiveActivity/LiveActivityBundle.swift`, `Trio/Sources/Shortcuts/Meal/MealWidgetIntents.swift`

**Interfaces — Consumes:** `QuickMeal.Store/Snapshot/Pending/confirmCheck/isGlucoseFresh/presets/widgetKind`, `MealIntentRequest` (Task 4). **Produces:** `MealPresetIntent(carbs: Int)`, `MealConfirmIntent`, `MealCancelIntent`, `MealWidget`.

- [ ] **Step 1: Intents**, appended to `MealWidgetIntents.swift`:

```swift
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
            case .expired, .stale:
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
```

(add `import WidgetKit` to the file). Cancel runs fine in either process, so it has no `#if`.
- [ ] **Step 2: Widget** `LiveActivity/Views/MealWidget.swift`:

```swift
import AppIntents
import SwiftUI
import WidgetKit

struct MealWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: QuickMeal.Snapshot?
    let pending: QuickMeal.Pending?
}

struct MealWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> MealWidgetEntry { MealWidgetEntry(date: Date(), snapshot: nil, pending: nil) }

    func getSnapshot(in _: Context, completion: @escaping (MealWidgetEntry) -> Void) { completion(entry(at: Date())) }

    func getTimeline(in _: Context, completion: @escaping (Timeline<MealWidgetEntry>) -> Void) {
        let now = Date()
        var entries = [entry(at: now)]
        // Return to the presets the moment a pending confirm expires.
        if let pending = QuickMeal.sharedStore?.pending {
            let expiry = pending.createdAt.addingTimeInterval(QuickMeal.pendingLifetime)
            if expiry > now { entries.append(MealWidgetEntry(date: expiry, snapshot: entries[0].snapshot, pending: nil)) }
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func entry(at date: Date) -> MealWidgetEntry {
        let store = QuickMeal.sharedStore
        var pending = store?.pending
        if let p = pending, date.timeIntervalSince(p.createdAt) > QuickMeal.pendingLifetime { pending = nil }
        return MealWidgetEntry(date: date, snapshot: store?.snapshot, pending: pending)
    }
}

struct MealWidgetView: View {
    let entry: MealWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            glance
            if let pending = entry.pending { confirmCard(pending) } else { presets }
        }
    }

    private var glance: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(entry.snapshot?.bg ?? "--") \(entry.snapshot?.direction ?? "")").font(.title2.bold())
            if let date = entry.snapshot?.glucoseDate { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Text("IOB \(entry.snapshot?.iob.formatted() ?? "-") U  COB \(entry.snapshot?.cob.formatted() ?? "-") g").font(.caption)
        }
    }

    private var glucoseFresh: Bool { QuickMeal.isGlucoseFresh(entry.snapshot?.glucoseDate, now: entry.date) }

    private var presets: some View {
        HStack {
            ForEach(QuickMeal.presets, id: \.self) { grams in
                Button(intent: MealPresetIntent(carbs: grams)) { Text("\(grams) g").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(.green)
            }
        }
    }

    @ViewBuilder private func confirmCard(_ pending: QuickMeal.Pending) -> some View {
        Text(pending.units > 0
            ? String(localized: "\(pending.carbs.formatted()) g → bolus \(pending.units.formatted()) U")
            : String(localized: "\(pending.carbs.formatted()) g, no bolus"))
            .font(.headline)
        HStack {
            if glucoseFresh {
                Button(intent: MealConfirmIntent()) { Text(pending.units > 0 ? "Confirm" : "Log").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.green)
            } else {
                Text(String(localized: "Glucose is over 15 min old")).font(.caption).foregroundStyle(.orange)
            }
            Button(intent: MealCancelIntent()) { Text("Cancel").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
        }
    }
}

struct MealWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: QuickMeal.widgetKind, provider: MealWidgetProvider()) { entry in
            MealWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Meal")
        .description("Glucose at a glance, and preset carbs with the recommended bolus.")
        .supportedFamilies([.systemMedium])
    }
}
```

- [ ] **Step 3:** `LiveActivityBundle.swift`: `var body: some Widget { LiveActivity(); MealWidget() }`.
- [ ] **Step 4:** Commit `quick meal: home-screen Meal widget`, push, CI green. Confirm logic is `QuickMeal.confirmCheck` (tested in Task 1); the expiry entry and store are tested in Tasks 1 and 5.

---

### Task 7 (controller): hand-over

- [ ] Whole-branch review (final reviewer subagent) against the spec and this plan's Review Focus.
- [ ] The spec's "a red test blocks the build" is held by process, not wiring: a TestFlight build is started only from a commit whose `unit_tests.yml` run is green.
- [ ] Build from the branch (not `beta`), so `beta` only moves after Ben's checks: `gh workflow run build_trio.yml -R wingrover/beta --ref quick-meal`. First Ben does the one-time Apple setup (Task 5's app group needs it for signing): (1) GitHub → wingrover/beta → Actions → "2. Add Identifiers" → Run; (2) developer.apple.com → Identifiers → `….LiveActivity` → App Groups → Configure → tick the Trio group → Save; (3) Actions → "3. Create Certificates" → Run. Write these out for him and wait for "done".
- [ ] After his checks 1–6 pass on the TestFlight build, merge `quick-meal` into `beta` (fast-forward) and push, so the monthly scheduled build keeps it.
