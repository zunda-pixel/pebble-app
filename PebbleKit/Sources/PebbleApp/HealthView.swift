import SwiftUI
import PebbleProtocol
import Charts
import UniformTypeIdentifiers

struct HealthView: View {
    var model: AppModel

    var body: some View {
        HealthContent(
            samples: model.health.samples,
            exportURL: model.health.exportURL,
            feedback: model.health.feedback,
            isWatchConnected: model.connectedWatch != nil,
            requestWatchSync: { Task { await model.requestHealthSync() } },
            synchronizeWithHealthKit: synchronizeWithHealthKit,
            importFromHealthKit: importFromHealthKit,
            export: { await model.exportHealthData() },
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
    var samples: [WatchHealthSample]
    var exportURL: URL?
    var feedback: FeatureFeedback?
    var isWatchConnected: Bool
    var requestWatchSync: () -> Void
    var synchronizeWithHealthKit: () -> Void
    var importFromHealthKit: () -> Void
    var export: @MainActor () async -> URL?
    var importArchive: (URL) -> Void
    var deleteLocalData: () -> Void

    @State private var period: HealthAnalysisPeriod = .week
    @State private var isImportingArchive = false
    @State private var isConfirmingDeletion = false
    @State private var isExporting = false

    var body: some View {
        List {
            Picker("Period", selection: $period) {
                ForEach(HealthAnalysisPeriod.allCases) { period in Text(period.title).tag(period) }
            }
            .pickerStyle(.segmented)
            // At the top, because it says things that arrive on their own —
            // "Received 3 health update(s) from the watch" turns up when the
            // watch pushes them, and at the foot of the list it sat below two
            // charts where it would never be seen.
            FeedbackBanner(feedback: feedback)
            Section {
                LabeledContent("Steps", value: newestSample?.steps ?? 0, format: .number)
                LabeledContent("Sleep") {
                    Text("\(newestSample?.sleepMinutes ?? 0) min")
                }
                if let deep = newestSample?.deepSleepMinutes, deep > 0 {
                    LabeledContent("Deep Sleep") {
                        Text("\(deep) min")
                    }
                }
                // Only Apple Health knows these, so they are shown when it has
                // been asked and left out when it has not.
                if let energy = newestSample?.activeKilocalories, energy > 0 {
                    LabeledContent("Active Energy") {
                        Text(Measurement(value: Double(energy), unit: UnitEnergy.kilocalories), format: .measurement(width: .abbreviated))
                    }
                }
                if let distance = newestSample?.distanceMetres, distance > 0 {
                    LabeledContent("Distance") {
                        Text(Measurement(value: Double(distance), unit: UnitLength.meters), format: .measurement(width: .abbreviated, usage: .road))
                    }
                }
                if let active = newestSample?.activeMinutes, active > 0 {
                    LabeledContent("Exercise") {
                        Text("\(active) min")
                    }
                }
                // The range rather than one number: the watch measures a
                // scattered handful of minutes, so a lone average would hide
                // both how high it went and how little it watched.
                if let heartRate = newestSample?.heartRate {
                    LabeledContent("Heart Rate") {
                        Text("\(heartRate.lowest)–\(heartRate.highest) bpm")
                    }
                    LabeledContent("Average Heart Rate") {
                        Text("\(heartRate.average) bpm")
                    }
                    LabeledContent("Minutes Measured", value: heartRate.measuredMinutes, format: .number)
                }
                // The range, like the heart rate: a scattered handful of measured
                // minutes, so the low and the high say more than one average.
                if let bloodOxygen = newestSample?.bloodOxygen {
                    LabeledContent("Blood Oxygen") {
                        Text("\(bloodOxygen.lowest)–\(bloodOxygen.highest)%")
                    }
                    LabeledContent("Average Blood Oxygen") {
                        Text("\(bloodOxygen.average)%")
                    }
                }
                // A night the watch broke into a sleep and a nap, or into two
                // halves with a wakeful hour between them, is two rows: one
                // range would say the reader slept through what they did not.
                ForEach(Array((newestSample?.sleepSessions ?? []).enumerated()), id: \.offset) { _, session in
                    LabeledContent {
                        Text("\(session.asleepMinutes) min")
                    } label: {
                        Text(
                            session.start..<session.end,
                            format: .interval.hour().minute()
                        )
                    }
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
                LabeledContent("Daily Average", value: averages.steps, format: .number)
                LabeledContent("Period Total", value: totalSteps, format: .number)
                LabeledContent("Best Day", value: bestStepCount, format: .number)
            }
            Section("Sleep") {
                Chart(filteredSamples) { sample in
                    LineMark(x: .value("Date", sample.date), y: .value("Minutes", sample.sleepMinutes))
                }
                .frame(minHeight: 180)
                LabeledContent("Daily Average") {
                    Text("\(averages.sleepMinutes) min")
                }
                if averages.deepSleepMinutes > 0 {
                    LabeledContent("Deep Sleep Average") {
                        Text("\(averages.deepSleepMinutes) min")
                    }
                }
                LabeledContent("Tracked Days", value: averages.sleepDays, format: .number)
            }
        }
        .navigationTitle(Text("Health"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Sync Health Data", systemImage: "arrow.triangle.2.circlepath", action: requestWatchSync)
                        .disabled(!isWatchConnected)
                    #if os(iOS)
                    Button("Sync with Apple Health", systemImage: "heart.fill", action: synchronizeWithHealthKit)
                    Button("Import from Apple Health", systemImage: "square.and.arrow.down", action: importFromHealthKit)
                    #endif
                    Section {
                        // Opens the sheet rather than writing the file here.
                        // Sharing what it wrote belongs beside the writing,
                        // not behind a second trip through this menu.
                        Button("Export Health Data", systemImage: "square.and.arrow.up") {
                            isExporting = true
                        }
                        Button("Import Health Archive", systemImage: "square.and.arrow.down.on.square") {
                            isImportingArchive = true
                        }
                    }
                    Section {
                        // Not a `ConfirmingButton` here. That one carries its
                        // own dialog, and a menu item's view is gone by the
                        // time the menu has closed, so the question would
                        // never be asked. The dialog belongs to the screen
                        // instead, below.
                        Button("Delete Local Health Data", systemImage: "trash", role: .destructive) {
                            isConfirmingDeletion = true
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .confirmationDialog(
            Text("Delete all local health data?"),
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Health Data", role: .destructive, action: deleteLocalData)
            Button(role: .cancel) {}
        } message: {
            Text("This removes locally stored step and sleep history. This action cannot be undone.")
        }
        .sheet(isPresented: $isExporting) {
            HealthExportSheet(existingExport: exportURL, export: export)
        }
        .fileImporter(isPresented: $isImportingArchive, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            importArchive(url)
        }
    }

    var newestSample: WatchHealthSample? {
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

    private var filteredSamples: [WatchHealthSample] {
        let start = Calendar.current.date(byAdding: .day, value: -period.days, to: Date()) ?? .distantPast
        return samples.filter { $0.date >= start }
    }

    /// Divided by the days that had something to say rather than by the days in
    /// the period: a watch that was off the wrist on Sunday should not read as
    /// a Sunday spent asleep for no minutes.
    private var averages: WatchHealthAverages { samples.averages(over: period.days) }

    private var totalSteps: Int { filteredSamples.map(\.steps).reduce(0, +) }

    private var bestStepCount: Int { filteredSamples.map(\.steps).max() ?? 0 }
}

#Preview("Two weeks") {
    NavigationStack {
        HealthContent(
            samples: PreviewSamples.healthSamples,
            exportURL: nil,
            feedback: .success("Received 3 health update(s) from the watch."),
            isWatchConnected: true,
            requestWatchSync: {},
            synchronizeWithHealthKit: {},
            importFromHealthKit: {},
            export: { nil },
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
            feedback: nil,
            isWatchConnected: false,
            requestWatchSync: {},
            synchronizeWithHealthKit: {},
            importFromHealthKit: {},
            export: { nil },
            importArchive: { _ in },
            deleteLocalData: {}
        )
    }
}
