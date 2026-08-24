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
}

enum HealthKitBridgeError: Error { case unavailable }
#endif
