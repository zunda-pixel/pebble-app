import SwiftUI
import API
import Charts
import UniformTypeIdentifiers

struct HealthView: View {
    var model: AppModel

    var body: some View {
        HealthContent(
            samples: model.healthSamples,
            exportURL: model.healthExportURL,
            statusMessage: model.dataSyncStatusMessage,
            isWatchConnected: model.connectedDevice != nil,
            requestWatchSync: { Task { await model.requestHealthSync() } },
            synchronizeWithHealthKit: synchronizeWithHealthKit,
            importFromHealthKit: importFromHealthKit,
            export: { Task { await model.exportHealthData() } },
            importArchive: { url in Task { await model.importHealthData(from: url) } },
            deleteLocalData: { Task { await model.deleteHealthData() } }
        )
        .task { await model.loadHealth() }
    }

    // Apple Health is on the phone only; the buttons that reach it are compiled
    // out elsewhere, and so is the work behind them.
    private var synchronizeWithHealthKit: () -> Void {
        #if os(iOS)
        { Task { await model.synchronizeWithHealthKit() } }
        #else
        {}
        #endif
    }

    private var importFromHealthKit: () -> Void {
        #if os(iOS)
        { Task { await model.importFromHealthKit() } }
        #else
        {}
        #endif
    }
}

struct HealthContent: View {
    var samples: [PebbleHealthSample]
    var exportURL: URL?
    var statusMessage: LocalizedStringKey?
    var isWatchConnected: Bool
    var requestWatchSync: () -> Void
    var synchronizeWithHealthKit: () -> Void
    var importFromHealthKit: () -> Void
    var export: () -> Void
    var importArchive: (URL) -> Void
    var deleteLocalData: () -> Void

    @State private var period: HealthAnalysisPeriod = .week
    @State private var isImportingArchive = false

    var body: some View {
        List {
            Picker("Period", selection: $period) {
                ForEach(HealthAnalysisPeriod.allCases) { period in Text(period.title).tag(period) }
            }
            .pickerStyle(.segmented)
            Section {
                LabeledContent("Steps", value: newestSample?.steps ?? 0, format: .number)
                LabeledContent("Sleep") {
                    Text("\(newestSample?.sleepMinutes ?? 0) min")
                }
            } header: {
                if let summaryDate {
                    Text("Last Recorded \(summaryDate, format: .dateTime.weekday(.abbreviated).month().day())")
                } else {
                    Text("Today")
                }
            }
            Section("Steps") {
                Chart(filteredSamples) { sample in
                    BarMark(x: .value("Date", sample.date), y: .value("Steps", sample.steps))
                }
                .frame(minHeight: 180)
                LabeledContent("Daily Average", value: averageSteps, format: .number)
                LabeledContent("Period Total", value: totalSteps, format: .number)
                LabeledContent("Best Day", value: bestStepCount, format: .number)
            }
            Section("Sleep") {
                Chart(filteredSamples) { sample in
                    LineMark(x: .value("Date", sample.date), y: .value("Minutes", sample.sleepMinutes))
                }
                .frame(minHeight: 180)
                LabeledContent("Daily Average") {
                    Text("\(averageSleep) min")
                }
                LabeledContent("Tracked Days", value: trackedSleepDays, format: .number)
            }
            Button("Sync Health Data", systemImage: "arrow.triangle.2.circlepath", action: requestWatchSync)
                .disabled(!isWatchConnected)
            #if os(iOS)
            Button("Sync with Apple Health", systemImage: "heart.fill", action: synchronizeWithHealthKit)
            Button("Import from Apple Health", systemImage: "square.and.arrow.down", action: importFromHealthKit)
            #endif
            Button("Export Health Data", systemImage: "square.and.arrow.up", action: export)
            if let exportURL { ShareLink(item: exportURL) { Text("Share Export") } }
            Button("Import Health Archive", systemImage: "square.and.arrow.down.on.square") {
                isImportingArchive = true
            }
            ConfirmingButton(
                title: "Delete Local Health Data",
                role: .destructive,
                question: "Delete all local health data?",
                explanation: "This removes locally stored step and sleep history. This action cannot be undone.",
                confirmationTitle: "Delete Health Data",
                action: deleteLocalData
            )
            if let statusMessage { Text(statusMessage).foregroundStyle(.secondary) }
        }
        .navigationTitle("Health")
        .fileImporter(isPresented: $isImportingArchive, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            importArchive(url)
        }
    }

    var newestSample: PebbleHealthSample? {
        samples.max { $0.date < $1.date }
    }

    /// A watch only hands over what it recorded, so the newest day it knows about
    /// can be days ago.
    var summaryDate: Date? {
        guard let date = newestSample?.date, !Calendar.current.isDateInToday(date) else {
            return nil
        }
        return date
    }

    private var filteredSamples: [PebbleHealthSample] {
        let start = Calendar.current.date(byAdding: .day, value: -period.days, to: Date()) ?? .distantPast
        return samples.filter { $0.date >= start }
    }

    private var averageSteps: Int {
        filteredSamples.isEmpty ? 0 : filteredSamples.map(\.steps).reduce(0, +) / filteredSamples.count
    }

    private var totalSteps: Int { filteredSamples.map(\.steps).reduce(0, +) }

    private var bestStepCount: Int { filteredSamples.map(\.steps).max() ?? 0 }

    private var averageSleep: Int {
        filteredSamples.isEmpty ? 0 : filteredSamples.map(\.sleepMinutes).reduce(0, +) / filteredSamples.count
    }

    private var trackedSleepDays: Int { filteredSamples.count { $0.sleepMinutes > 0 } }
}

#Preview("Two weeks") {
    NavigationStack {
        HealthContent(
            samples: PreviewSamples.healthSamples,
            exportURL: nil,
            statusMessage: "Received 3 health update(s) from the watch.",
            isWatchConnected: true,
            requestWatchSync: {},
            synchronizeWithHealthKit: {},
            importFromHealthKit: {},
            export: {},
            importArchive: { _ in },
            deleteLocalData: {}
        )
    }
}

#Preview("Nothing recorded") {
    NavigationStack {
        HealthContent(
            samples: [],
            exportURL: nil,
            statusMessage: nil,
            isWatchConnected: false,
            requestWatchSync: {},
            synchronizeWithHealthKit: {},
            importFromHealthKit: {},
            export: {},
            importArchive: { _ in },
            deleteLocalData: {}
        )
    }
}
