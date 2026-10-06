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
