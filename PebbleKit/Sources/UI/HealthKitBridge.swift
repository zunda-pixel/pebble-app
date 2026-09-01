#if os(iOS)
import API
import Defaults
import Foundation
import HealthKit

@MainActor
final class HealthKitBridge {
    private var store = HKHealthStore()
    private var lastExportDate: Date {
        get { Defaults[.healthKitLastExportDate] }
        set { Defaults[.healthKitLastExportDate] = newValue }
    }

    /// Whether writing to HealthKit may ask for permission first.
    ///
    /// Asking puts a full-screen sheet over whatever the reader is doing, so
    /// only something the reader started may do it. Health data arriving from
    /// a watch is not that: it turns up whenever a watch answers a
    /// synchronization request, in the middle of any screen.
    enum Authorization {
        case mayAsk
        case onlyWhatIsAlreadyGranted
    }

    func synchronize(
        _ samples: [PebbleHealthSample],
        authorization: Authorization = .mayAsk
    ) async throws {
        guard HKHealthStore.isHealthDataAvailable(),
              let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount),
              let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitBridgeError.unavailable
        }
        switch authorization {
        case .mayAsk:
            try await store.requestAuthorization(toShare: [stepsType, sleepType], read: [stepsType, sleepType])
        case .onlyWhatIsAlreadyGranted:
            // Writing is the one side HealthKit lets an app read back, and it
            // is the side used here.
            guard store.authorizationStatus(for: stepsType) == .sharingAuthorized else {
                throw HealthKitBridgeError.notGranted
            }
        }
        let changedSamples = samples.filter { $0.updatedAt > lastExportDate && $0.source != .healthKit }
        var healthSamples: [HKSample] = []
        for sample in changedSamples {
            let version = max(1, Int(sample.updatedAt.timeIntervalSince1970))
            let baseIdentifier = "pebble.\(sample.id.uuidString.lowercased())"
            let commonMetadata: [String: Any] = [
                HKMetadataKeyExternalUUID: sample.id.uuidString,
                HKMetadataKeySyncVersion: version,
            ]
            var stepsMetadata = commonMetadata
            stepsMetadata[HKMetadataKeySyncIdentifier] = "\(baseIdentifier).steps"
            healthSamples.append(HKQuantitySample(
                type: stepsType,
                quantity: HKQuantity(unit: .count(), doubleValue: Double(sample.steps)),
                start: sample.date,
                end: sample.date.addingTimeInterval(60),
                metadata: stepsMetadata
            ))
            if sample.sleepMinutes > 0 {
                var sleepMetadata = commonMetadata
                sleepMetadata[HKMetadataKeySyncIdentifier] = "\(baseIdentifier).sleep"
                healthSamples.append(HKCategorySample(
                    type: sleepType,
                    value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    start: sample.date.addingTimeInterval(TimeInterval(-sample.sleepMinutes * 60)),
                    end: sample.date,
                    metadata: sleepMetadata
                ))
            }
        }
        if !healthSamples.isEmpty {
            try await store.save(healthSamples)
            lastExportDate = changedSamples.map(\.updatedAt).max() ?? lastExportDate
        }
    }

    func readRecentSamples(days: Int = 90) async throws -> [PebbleHealthSample] {
        guard HKHealthStore.isHealthDataAvailable(),
              let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount),
              let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitBridgeError.unavailable
        }
        try await store.requestAuthorization(toShare: [], read: [stepsType, sleepType])
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let end = Date()
        async let stepSamples = query(type: stepsType, start: start, end: end)
        async let sleepSamples = query(type: sleepType, start: start, end: end)
        var stepsBySource: [Date: [String: Int]] = [:]
        var sleepBySource: [Date: [String: Int]] = [:]
        var updatedAtByDay: [Date: Date] = [:]
        for case let sample as HKQuantitySample in try await stepSamples {
            guard !(sample.metadata?[HKMetadataKeySyncIdentifier] as? String ?? "").hasPrefix("pebble.") else { continue }
            let day = Calendar.current.startOfDay(for: sample.startDate)
            let source = sample.sourceRevision.source.bundleIdentifier
            stepsBySource[day, default: [:]][source, default: 0] += Int(sample.quantity.doubleValue(for: .count()))
            updatedAtByDay[day] = max(updatedAtByDay[day] ?? .distantPast, sample.endDate)
        }
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        for case let sample as HKCategorySample in try await sleepSamples where asleepValues.contains(sample.value) {
            guard !(sample.metadata?[HKMetadataKeySyncIdentifier] as? String ?? "").hasPrefix("pebble.") else { continue }
            let day = Calendar.current.startOfDay(for: sample.endDate)
            let source = sample.sourceRevision.source.bundleIdentifier
            sleepBySource[day, default: [:]][source, default: 0] += Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
            updatedAtByDay[day] = max(updatedAtByDay[day] ?? .distantPast, sample.endDate)
        }
        let days = Set(stepsBySource.keys).union(sleepBySource.keys)
        return days.map { day in
            PebbleHealthSample(
                date: day,
                steps: stepsBySource[day]?.values.max() ?? 0,
                sleepMinutes: min(24 * 60, sleepBySource[day]?.values.max() ?? 0),
                source: .healthKit,
                updatedAt: updatedAtByDay[day] ?? day
            )
        }
    }

    private func query(type: HKSampleType, start: Date, end: Date) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }
}

enum HealthKitBridgeError: Error {
    case unavailable
    /// Writing has not been allowed, and this is not a moment when the reader
    /// may be asked. Nothing was written and nothing is wrong.
    case notGranted
}
#endif
