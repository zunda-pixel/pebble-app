#if os(iOS)
import API
import Foundation
import HealthKit

@MainActor
final class HealthKitBridge {
    private var store = HKHealthStore()

    func synchronize(_ samples: [PebbleHealthSample]) async throws {
        guard HKHealthStore.isHealthDataAvailable(),
              let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount),
              let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitBridgeError.unavailable
        }
        try await store.requestAuthorization(toShare: [stepsType, sleepType], read: [stepsType, sleepType])
        var healthSamples: [HKSample] = []
        for sample in samples {
            let metadata = [HKMetadataKeyExternalUUID: sample.id.uuidString]
            healthSamples.append(HKQuantitySample(
                type: stepsType,
                quantity: HKQuantity(unit: .count(), doubleValue: Double(sample.steps)),
                start: sample.date,
                end: sample.date,
                metadata: metadata
            ))
            if sample.sleepMinutes > 0 {
                healthSamples.append(HKCategorySample(
                    type: sleepType,
                    value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    start: sample.date.addingTimeInterval(TimeInterval(-sample.sleepMinutes * 60)),
                    end: sample.date,
                    metadata: metadata
                ))
            }
        }
        if !healthSamples.isEmpty { try await store.save(healthSamples) }
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
        var daily: [Date: (steps: Int, sleep: Int)] = [:]
        for case let sample as HKQuantitySample in try await stepSamples {
            let day = Calendar.current.startOfDay(for: sample.startDate)
            daily[day, default: (0, 0)].steps += Int(sample.quantity.doubleValue(for: .count()))
        }
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        for case let sample as HKCategorySample in try await sleepSamples where asleepValues.contains(sample.value) {
            let day = Calendar.current.startOfDay(for: sample.endDate)
            daily[day, default: (0, 0)].sleep += Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
        }
        return daily.map { PebbleHealthSample(date: $0.key, steps: $0.value.steps, sleepMinutes: $0.value.sleep) }
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

enum HealthKitBridgeError: Error { case unavailable }
#endif
