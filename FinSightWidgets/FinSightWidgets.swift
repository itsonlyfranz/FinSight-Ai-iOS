import SwiftUI
import WidgetKit

struct SpendingEntry: TimelineEntry {
    let date: Date
    let snapshot: SystemSnapshot?
}

struct SpendingProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpendingEntry { SpendingEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping @Sendable (SpendingEntry) -> Void) {
        Task { @MainActor in completion(SpendingEntry(date: .now, snapshot: try? SystemSnapshot.load())) }
    }
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<SpendingEntry>) -> Void) {
        Task { @MainActor in
            let now = Date.now
            let entry = SpendingEntry(date: now, snapshot: try? SystemSnapshot.load(now: now))
            completion(Timeline(entries: [entry], policy: .after(SystemSnapshot.nextRefresh(after: now))))
        }
    }
}

struct SpendingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SpendingEntry
    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .accessoryCircular:
                    Gauge(value: snapshot.progress) { Image(systemName: "chart.pie") }
                        .gaugeStyle(.accessoryCircularCapacity)
                case .accessoryInline:
                    Text("Month: \(snapshot.spendText)")
                case .accessoryRectangular:
                    VStack(alignment: .leading) {
                        Text("Month spending").font(.caption)
                        Text(snapshot.spendText).font(.headline)
                        if let due = snapshot.due.first { Text("Next: \(due.merchant)").font(.caption).lineLimit(1) }
                    }
                default:
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("This month").font(.caption).foregroundStyle(.secondary)
                            Text(snapshot.spendText).font(.headline).minimumScaleFactor(0.6)
                            Gauge(value: snapshot.progress) { Text("Budget") }
                                .gaugeStyle(.linearCapacity)
                            Text(snapshot.budget > 0 ? "of \(snapshot.budget.formatted(.currency(code: snapshot.currency)))" : "No budget set")
                                .font(.caption2).foregroundStyle(.secondary)
                            if family == .systemSmall {
                                Text(snapshot.topCategory ?? "No spending yet").font(.caption2).lineLimit(1)
                                Text(snapshot.due.first.map { "Next: \($0.merchant)" } ?? "No bills upcoming").font(.caption2).lineLimit(1)
                            }
                        }
                        if family == .systemMedium {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Top category").font(.caption).foregroundStyle(.secondary)
                                Text(snapshot.topCategory ?? "No spending yet").font(.subheadline)
                                Text("Next recurring").font(.caption).foregroundStyle(.secondary)
                                if let due = snapshot.due.first {
                                    Text(due.merchant).font(.subheadline).lineLimit(1)
                                    Text(due.date, style: .date).font(.caption2)
                                } else { Text("None upcoming").font(.caption) }
                            }
                        }
                    }
                }
            } else {
                Text("Open FinSight AI to connect your ledger").font(.caption)
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "finsight://dashboard"))
        .privacySensitive()
    }
}

struct SpendingWidget: Widget {
    let kind = "com.finsightai.spending"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SpendingProvider()) { SpendingWidgetView(entry: $0) }
            .configurationDisplayName("FinSight Spending")
            .description("Month spending, budget progress and upcoming recurring expenses.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct ExpenseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.finsightai.addExpense") {
            ControlWidgetButton(action: OpenExpenseControlIntent()) { Label("Add Expense", systemImage: "plus.circle.fill") }
        }
        .displayName("Add FinSight Expense")
        .description("Open the expense editor in FinSight AI.")
    }
}

@main
struct FinSightWidgetBundle: WidgetBundle {
    var body: some Widget {
        SpendingWidget()
        ExpenseControl()
    }
}
