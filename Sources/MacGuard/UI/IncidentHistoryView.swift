import SwiftUI
import MacGuardCore

struct IncidentHistoryView: View {
    @EnvironmentObject var c: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("Event History").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            if c.events.isEmpty {
                VStack(spacing: 8) { Image(systemName: "clock").font(.largeTitle); Text("No events yet").font(.headline); Text("Arming, charger changes, alarms and notifications will appear here.").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(c.events) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.type.title).bold()
                            if e.isTest { Text("TEST").font(.caption2.bold()).padding(.horizontal, 5).background(.blue.opacity(0.25), in: Capsule()) }
                            Spacer()
                            Text(e.timestamp.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(e.result).font(.callout).foregroundStyle(.secondary)
                        if let id = e.incidentID { Text("Incident \(id.uuidString)").font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                    }.accessibilityElement(children: .combine)
                }
            }
        }.padding()
    }
}

struct FindMyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recover with Find My").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(FindMyRecoveryGuide.steps.enumerated()), id: \.offset) { i, s in
                        VStack(alignment: .leading) { Text("\(i + 1). \(s.title)").bold(); Text(s.body).foregroundStyle(.secondary) }
                    }
                    Text(FindMyRecoveryGuide.disclaimer).font(.callout).padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            HStack {
                Button("OPEN FIND MY") { NSWorkspace.shared.open(FindMyRecoveryGuide.findMyURL) }.buttonStyle(.borderedProminent)
                Spacer(); Button("Done") { dismiss() }
            }
        }.padding()
    }
}
