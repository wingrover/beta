import AppIntents
import SwiftUI
import WidgetKit

struct MealWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: QuickMeal.Snapshot?
    let pending: QuickMeal.Pending?
    let outcome: QuickMeal.Outcome?
}

struct MealWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> MealWidgetEntry {
        MealWidgetEntry(date: Date(), snapshot: nil, pending: nil, outcome: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping (MealWidgetEntry) -> Void) { completion(entry(at: Date())) }

    func getTimeline(in _: Context, completion: @escaping (Timeline<MealWidgetEntry>) -> Void) {
        let now = Date()
        let store = QuickMeal.sharedStore
        // Change points: the confirm card expiring (back to the presets) and the outcome line expiring.
        var changes: [Date] = []
        if let pending = store?.pending { changes.append(pending.createdAt.addingTimeInterval(QuickMeal.pendingLifetime)) }
        if let outcome = store?.lastOutcome { changes.append(outcome.date.addingTimeInterval(QuickMeal.outcomeLifetime)) }
        changes = changes.filter { $0 > now }.sorted()
        let entries = [entry(at: now)] + changes.map { entry(at: $0) }
        // Nothing due to change: wait for the app to push a reload, which keeps the reload budget for glucose.
        completion(Timeline(entries: entries, policy: changes.isEmpty ? .never : .atEnd))
    }

    private func entry(at date: Date) -> MealWidgetEntry {
        let store = QuickMeal.sharedStore
        var pending = store?.pending
        if let p = pending, date.timeIntervalSince(p.createdAt) >= QuickMeal.pendingLifetime { pending = nil }
        var outcome = store?.lastOutcome
        if let o = outcome, date.timeIntervalSince(o.date) >= QuickMeal.outcomeLifetime { outcome = nil }
        return MealWidgetEntry(date: date, snapshot: store?.snapshot, pending: pending, outcome: outcome)
    }
}

struct MealWidgetView: View {
    let entry: MealWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            glance
            if let pending = entry.pending { confirmCard(pending) } else {
                if let outcome = entry.outcome {
                    Text(outcome.message).font(.caption).lineLimit(2).minimumScaleFactor(0.7)
                        .foregroundStyle(outcome.isWarning ? Color.orange : Color.secondary)
                }
                presets
            }
        }
    }

    private var glance: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(entry.snapshot?.bg ?? "--") \(entry.snapshot?.direction ?? "")").font(.title2.bold())
            if let date = entry.snapshot?.glucoseDate { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Text("IOB \(entry.snapshot?.iob.formatted() ?? "-") U  COB \(entry.snapshot?.cob.formatted() ?? "-") g")
                .font(.caption)
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
        Text(
            pending.units > 0
                ? String(localized: "\(pending.carbs.formatted()) g → bolus \(pending.units.formatted()) U")
                : String(localized: "\(pending.carbs.formatted()) g, no bolus")
        )
        .font(.headline)
        HStack {
            if glucoseFresh {
                Button(intent: MealConfirmIntent()) { Text(pending.units > 0 ? "Confirm" : "Log").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(.green)
            } else {
                Text(String(localized: "Glucose is over 15 min old: enter the bolus yourself"))
                    .font(.caption).lineLimit(2).minimumScaleFactor(0.7).foregroundStyle(.orange)
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
