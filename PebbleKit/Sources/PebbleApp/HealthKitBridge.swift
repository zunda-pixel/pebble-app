#if os(iOS)
import PebbleProtocol
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

    /// Asking puts a full-screen sheet over whatever the reader is doing, so only
    /// something the reader started may ask.
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
            // Writing is the one side HealthKit lets an app read back.
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

    /// What a day cost in effort, alongside the steps and the sleep. The watch
    /// counts these itself and keeps them to itself — its data-logging sessions
    /// carry only steps and sleep — so this is where they come from.
    private enum EffortMeasure: CaseIterable {
        case activeEnergy
        case restingEnergy
        case distance
        case exerciseTime

        var identifier: HKQuantityTypeIdentifier {
            switch self {
            case .activeEnergy: .activeEnergyBurned
            case .restingEnergy: .basalEnergyBurned
            case .distance: .distanceWalkingRunning
            case .exerciseTime: .appleExerciseTime
            }
        }

        var unit: HKUnit {
            switch self {
            case .activeEnergy, .restingEnergy: .kilocalorie()
            case .distance: .meter()
            case .exerciseTime: .minute()
            }
        }
    }

    func readRecentSamples(days: Int = 90) async throws -> [PebbleHealthSample] {
        guard HKHealthStore.isHealthDataAvailable(),
              let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount),
              let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitBridgeError.unavailable
        }
        let effortTypes = EffortMeasure.allCases.reduce(into: [EffortMeasure: HKQuantityType]()) { types, measure in
            types[measure] = HKQuantityType.quantityType(forIdentifier: measure.identifier)
        }
        // A phone that will not give one of these still has the others; the
        // reader is asked for everything at once and told nothing about what
        // they refused, so a missing measure is simply a zero.
        try await store.requestAuthorization(
            toShare: [],
            read: Set([stepsType, sleepType] as [HKObjectType] + effortTypes.values.map { $0 as HKObjectType })
        )
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
        var effortBySource: [EffortMeasure: [Date: [String: Int]]] = [:]
        for (measure, type) in effortTypes {
            for case let sample as HKQuantitySample in try await query(type: type, start: start, end: end) {
                let day = Calendar.current.startOfDay(for: sample.startDate)
                let source = sample.sourceRevision.source.bundleIdentifier
                effortBySource[measure, default: [:]][day, default: [:]][source, default: 0]
                    += Int(sample.quantity.doubleValue(for: measure.unit))
                updatedAtByDay[day] = max(updatedAtByDay[day] ?? .distantPast, sample.endDate)
            }
        }

        let days = Set(stepsBySource.keys)
            .union(sleepBySource.keys)
            .union(effortBySource.values.flatMap(\.keys))
        return days.map { day in
            // The busiest source rather than the sum of them: a phone and a
            // watch both counting the same walk would otherwise report it
            // twice.
            func effort(_ measure: EffortMeasure) -> Int {
                effortBySource[measure]?[day]?.values.max() ?? 0
            }
            return PebbleHealthSample(
                date: day,
                steps: stepsBySource[day]?.values.max() ?? 0,
                sleepMinutes: min(24 * 60, sleepBySource[day]?.values.max() ?? 0),
                activeKilocalories: effort(.activeEnergy),
                restingKilocalories: effort(.restingEnergy),
                distanceMetres: effort(.distance),
                activeMinutes: effort(.exerciseTime),
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
    /// Writing has not been allowed and this is not a moment when the reader may
    /// be asked.
    case notGranted
}
#endif
