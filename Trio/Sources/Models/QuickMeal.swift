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
