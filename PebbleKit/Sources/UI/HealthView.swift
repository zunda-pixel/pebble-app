import SwiftUI
import API
import Charts
import UniformTypeIdentifiers

struct HealthView: View {
    var model: AppModel
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
            Button("Sync Health Data", systemImage: "arrow.triangle.2.circlepath") {
                Task { await model.requestHealthSync() }
            }
            .disabled(model.connectedDevice == nil)
            #if os(iOS)
            Button("Sync with Apple Health", systemImage: "heart.fill") {
                Task { await model.synchronizeWithHealthKit() }
            }
            Button("Import from Apple Health", systemImage: "square.and.arrow.down") {
                Task { await model.importFromHealthKit() }
            }
            #endif
            Button("Export Health Data", systemImage: "square.and.arrow.up") {
                Task { await model.exportHealthData() }
            }
            if let url = model.healthExportURL { ShareLink(item: url) { Text("Share Export") } }
            Button("Import Health Archive", systemImage: "square.and.arrow.down.on.square") {
                isImportingArchive = true
            }
            ConfirmingButton(
                title: "Delete Local Health Data",
                role: .destructive,
                question: "Delete all local health data?",
                explanation: "This removes locally stored step and sleep history. This action cannot be undone.",
                confirmationTitle: "Delete Health Data"
            ) {
                Task { await model.deleteHealthData() }
            }
            if let message = model.dataSyncStatusMessage { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("Health")
        .task { await model.loadHealth() }
        .fileImporter(isPresented: $isImportingArchive, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.importHealthData(from: url) }
        }
    }

    /// The most recent day there is anything for, whatever day that is.
    var newestSample: PebbleHealthSample? {
        model.healthSamples.max { $0.date < $1.date }
    }

    /// The day the summary is actually showing, when that is not today.
    ///
    /// A watch only hands over what it recorded, so the newest day it knows
    /// about can be days old: one last worn on Friday reports Friday. Saying
    /// which day it is beats showing Friday's steps as this morning's.
    var summaryDate: Date? {
        guard let date = newestSample?.date, !Calendar.current.isDateInToday(date) else {
            return nil
        }
        return date
    }

    private var filteredSamples: [PebbleHealthSample] {
        let start = Calendar.current.date(byAdding: .day, value: -period.days, to: Date()) ?? .distantPast
        return model.healthSamples.filter { $0.date >= start }
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
