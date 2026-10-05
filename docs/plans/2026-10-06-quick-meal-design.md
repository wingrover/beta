# Quick Meal: carbs to bolus in one confirm

**Change:** three quick ways to log a meal and give the recommended bolus with one confirm: a Meal button on the lock-screen Live Activity (opens Beta, Face ID), a Meal Shortcut (Beta stays closed, confirm pop-up), and a Beta home-screen widget with preset carb buttons (Beta stays closed, confirm in the widget).

## Flow

```
Lock screen / Dynamic Island           Beta: meal screen (Treatments)
┌──────────────────────────┐           ┌──────────────────────────────────┐
│ 7.8 ↗   IOB 1.2  COB 20  │  tap      │ BG 7.8 ↗   IOB 1.2 U   COB 20 g  │
│ ~~~~~ trend chart ~~~~~  │  Meal     │ Carbs  [ 40 ]  ← focused, keypad │
│                 [ Meal ] │ ───────►  │ Bolus  [ 4.2 ] ← follows the     │
└──────────────────────────┘ Trio://   │                  recommendation  │
                             meal      │ [ Log 40 g + bolus 4.2 U ]       │
                                       └───────────────┬──────────────────┘
                                                       ▼
                                          Face ID (existing UnlockManager)
                                                       ▼
                                          carbs saved, then bolus enacted
```

## What changes

1. **Meal button** on the Live Activity's lock-screen view and expanded Dynamic Island, linking to `Trio://meal`.
2. **`Trio://meal` route** in the app's URL handler opens the Treatments screen with the carbs field focused.
3. **Bolus follows the recommendation.** While the bolus field has not been edited by hand, it is set to Trio's calculated, rounded bolus (`insulinCalculated`, already capped at max bolus) every time that value changes. Editing the bolus field stops the following for that screen visit. This applies however the screen is opened.
4. **One button label** states both actions: `Log 40 g + bolus 4.2 U`; `Log 40 g` when the bolus is 0; `Bolus 4.2 U` when carbs are 0 (unchanged meaning, new wording).
5. **Meal Shortcut** (new App Intent, "Log meal with recommended bolus"), run from a home-screen icon, the Action button or Siri, without opening Beta:
   ```
   "Carbs?" (number pad) ─► calculator (bolusCalculationManager) ─► "Log 40 g and bolus 4.2 U?" [Confirm]
                                                                       ─► carbs saved ─► bolus via the existing Shortcut safety check
   ```
   - `authenticationPolicy = .requiresAuthentication`: will not run on a locked phone (iOS asks to unlock first). No Face ID at the moment of dosing; the gate is the unlocked phone plus the confirm pop-up, which always shows grams and units.
   - Bolus goes through `BolusIntentRequest`'s existing safety validator and only when Settings → Shortcuts → bolus is set to "limit with safety checks" (off by default; Ben turns it on). If it is off, the Shortcut logs the carbs and says the bolus was not sent.
   - Same stale (> 15 min) and zero rules as the screen: stale stops with a message before anything is logged; 0 recommended asks "Log 40 g? (no bolus recommended)".
6. **Meal widget** (home screen, medium size), added to the existing `LiveActivity` widget bundle so no new app target:
   ```
   ┌───────────────────────────────┐  tap 30   ┌───────────────────────────────┐
   │ 7.8 ↗  4 min ago              │ ───────►  │ 30 g → bolus 3.1 U            │
   │ IOB 1.2 U   COB 20 g          │           │ [ Confirm ]   [ Cancel ]      │
   │ [15] [30] [45] [60] g         │ ◄───────  │ expires in 60 s               │
   └───────────────────────────────┘  cancel / └───────────────────────────────┘
                                      timeout
   ```
   - **Glance:** Beta writes a snapshot (BG, trend, reading time, IOB, COB) to the shared app-group container on each loop and asks iOS to refresh the widget. iOS rations refreshes, so the snapshot can lag 15–30 min; the reading's age is always shown beside it.
   - **Preset tap** runs an intent in Beta's process (`LiveActivityIntent`): it calculates the bolus for those carbs now (`bolusCalculationManager`), stores a pending `{carbs, units, time}` in the app group, and the widget redraws to the confirm card. Interactive redraws are immediate.
   - **Confirm** re-checks before acting: pending is under 60 s old, glucose ≤ 15 min old, and a fresh calculation still gives the units shown. If the units changed, nothing is dosed and the card shows the new amount to confirm again. Then carbs are saved and the bolus goes through `BolusIntentRequest`'s safety validator (same Shortcut bolus setting as item 5). Pending is cleared.
   - **Cancel**, or 60 s passing, clears pending and returns the presets. 0 recommended shows `30 g, no bolus [Log] [Cancel]`. Stale glucose shows the reading's age and no confirm button.
   - Home screen only: interactive widgets need an unlocked phone. Presets fixed at 15/30/45/60 g.
   - **One-time setup (Ben, on GitHub and developer.apple.com):** the widget's extension (`….LiveActivity`) needs the Trio app group. The build's `Add Identifiers` step gets App Groups for it (as the watch complication already has); then add the Trio app group to that identifier on developer.apple.com, and re-run `Create Certificates`. The agent writes the steps out when the code is ready.

## Safety rules

- **Stale glucose:** if the latest reading is more than 15 minutes old, the bolus does not follow; it stays at 0 and a line reads "Glucose is over 15 min old: enter the bolus yourself".
- **Recommendation 0** (e.g. low or falling): bolus stays 0, the button only logs carbs.
- Face ID before any bolus, the max-bolus cap and the existing failure alert are unchanged. If the bolus fails, the carbs stay logged and the alert says the bolus was not given.
- No change to the dosing algorithm, SMB, or anything the loop calculates.

## Out of scope

Fat/protein and meal presets in the quick paths; lock-screen widgets; editable preset amounts; glucose on the widget fresher than iOS allows; Control Center or Action button; an on/off setting; the sprout icon (already on `beta`, rides along).

## Where

- `LiveActivity/` lock-screen and expanded views: the button.
- `Trio/Sources/Application/TrioApp.swift` `handleURL`: the route.
- `Trio/Sources/Modules/Treatments/`: focus, follow-the-recommendation, stale rule, label.
- `Trio/Sources/Shortcuts/Meal/` (new): the Meal intent and its request, reusing `bolusCalculationManager`, `CarbsStorage` and `BolusIntentRequest`; the widget's preset, confirm and cancel intents share this request.
- `LiveActivity/` (new widget beside the Live Activity), its entitlements (app group), `fastlane/Fastfile` (App Groups capability on the LiveActivity identifier), and the app's snapshot writer.
- `TrioTests/`: unit tests for follow / stop-following / stale / zero, the Meal intent's stale, zero and bolus-disabled paths, and the widget's confirm re-checks (expired, stale, units changed), run by `unit_tests.yml` on GitHub (the box cannot build iOS); a red test blocks the build.

## Acceptance checks (on your phone, from TestFlight)

1. Tap **Meal** on the lock-screen Live Activity: Face ID unlocks into Beta's meal screen with the carbs box focused and the keypad up.
2. Type carbs: the bolus box changes with each digit and matches the recommendation shown; the button reads `Log N g + bolus X U`. Back out without confirming: nothing logged.
3. Type a bolus by hand, then change the carbs: your bolus stays put.
4. With 0 recommended (or after editing bolus to 0), confirm: carbs appear in history and no bolus is given.
5. Add the Meal Shortcut to the home screen and run it with Beta closed: it asks for carbs, shows `Log N g and bolus X U?`, and Cancel logs nothing. With the Shortcut bolus setting off, Confirm logs carbs only and says so.
6. Add the Meal widget: it shows BG with its age, IOB and COB. Tap 30: the card shows `30 g → bolus X U`; Cancel logs nothing; tapping 30 and waiting 60 s returns to the presets with nothing logged. With the Shortcut bolus setting off, Confirm logs carbs only.

First real dose only after checks 1–6 pass.
