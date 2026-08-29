import SwiftUI
import API
import Charts

struct HealthView: View {
    var model: AppModel
    @State private var period: HealthAnalysisPeriod = .week
    @State private var isImportingArchive = false
    @State private var isConfirmingHealthDeletion = false

    var body: some View {
        List {
            Picker("Period", selection: $period) {
                ForEach(HealthAnalysisPeriod.allCases) { period in Text(period.rawValue.capitalized).tag(period) }
            }
            .pickerStyle(.segmented)
            Section("Today") {
                LabeledContent("Steps", value: "\(model.healthSamples.last?.steps ?? 0)")
                LabeledContent("Sleep", value: "\(model.healthSamples.last?.sleepMinutes ?? 0) min")
            }
            Section("Steps") {
                Chart(filteredSamples) { sample in
                    BarMark(x: .value("Date", sample.date), y: .value("Steps", sample.steps))
                }
                .frame(minHeight: 180)
                LabeledContent("Daily Average", value: "\(averageSteps)")
                LabeledContent("Period Total", value: "\(totalSteps)")
                LabeledContent("Best Day", value: "\(bestStepCount)")
            }
            Section("Sleep") {
                Chart(filteredSamples) { sample in
                    LineMark(x: .value("Date", sample.date), y: .value("Minutes", sample.sleepMinutes))
                }
                .frame(minHeight: 180)
                LabeledContent("Daily Average", value: "\(averageSleep) min")
                LabeledContent("Tracked Days", value: "\(trackedSleepDays)")
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
            Button("Delete Local Health Data", role: .destructive) {
                isConfirmingHealthDeletion = true
            }
            if let message = model.dataSyncStatusMessage { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("Health")
        .task { await model.loadHealth() }
        .fileImporter(isPresented: $isImportingArchive, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.importHealthData(from: url) }
        }
        .confirmationDialog(
            "Delete all local health data?",
            isPresented: $isConfirmingHealthDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Health Data", role: .destructive) {
                Task { await model.deleteHealthData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes locally stored step and sleep history. This action cannot be undone.")
        }
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
