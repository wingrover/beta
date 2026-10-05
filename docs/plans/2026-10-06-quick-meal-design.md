# Quick Meal: carbs to bolus in one confirm

**Change:** a Meal button on the lock-screen Live Activity opens the meal screen ready to type, the bolus box fills itself with Trio's recommendation, and one Face ID confirm logs the carbs and gives the bolus.

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

## Safety rules

- **Stale glucose:** if the latest reading is more than 15 minutes old, the bolus does not follow; it stays at 0 and a line reads "Glucose is over 15 min old: enter the bolus yourself".
- **Recommendation 0** (e.g. low or falling): bolus stays 0, the button only logs carbs.
- Face ID before any bolus, the max-bolus cap and the existing failure alert are unchanged. If the bolus fails, the carbs stay logged and the alert says the bolus was not given.
- No change to the dosing algorithm, SMB, or anything the loop calculates.

## Out of scope

Fat/protein and meal presets in the quick path; home-screen widgets; Control Center or Action button; an on/off setting; the sprout icon (already on `beta`, rides along).

## Where

- `LiveActivity/` lock-screen and expanded views: the button.
- `Trio/Sources/Application/TrioApp.swift` `handleURL`: the route.
- `Trio/Sources/Modules/Treatments/`: focus, follow-the-recommendation, stale rule, label.
- `TrioTests/`: unit tests for follow / stop-following / stale / zero, run by `unit_tests.yml` on GitHub (the box cannot build iOS); a red test blocks the build.

## Acceptance checks (on your phone, from TestFlight)

1. Tap **Meal** on the lock-screen Live Activity: Face ID unlocks into Beta's meal screen with the carbs box focused and the keypad up.
2. Type carbs: the bolus box changes with each digit and matches the recommendation shown; the button reads `Log N g + bolus X U`. Back out without confirming: nothing logged.
3. Type a bolus by hand, then change the carbs: your bolus stays put.
4. With 0 recommended (or after editing bolus to 0), confirm: carbs appear in history and no bolus is given. First real use only after checks 1–3 pass.
