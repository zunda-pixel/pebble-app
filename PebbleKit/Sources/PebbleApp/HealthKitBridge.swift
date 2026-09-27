#if os(iOS)
import PebbleProtocol
import Defaults
import Foundation
import HealthKit

@MainActor
final class HealthKitBridge {
    private var store = HKHealthStore()

    /// The types the export writes, each with a cursor of its own: what one
    /// type has exported must not decide what another still owes. A single
    /// cursor stranded any day that arrived while its type's permission was
    /// still refused — the other types dragged the cursor past it, and the
    /// permission arriving later found nothing left to export.
    private enum ExportKind: String, CaseIterable {
        case steps, sleep, heartRate, workouts, bloodOxygen
    }

    private func exportCursor(_ kind: ExportKind) -> Date {
        Defaults[.healthKitLastExportDates][kind.rawValue] ?? .distantPast
    }

    private func advanceExportCursor(_ kind: ExportKind, to date: Date) {
        if date > exportCursor(kind) {
            Defaults[.healthKitLastExportDates][kind.rawValue] = date
        }
    }

    /// Asking puts a full-screen sheet over whatever the reader is doing, so only
    /// something the reader started may ask.
    enum Authorization {
        case mayAsk
        case onlyWhatIsAlreadyGranted
    }

    /// Asks for everything the app ever uses, for the setup flow: HealthKit puts
    /// one sheet up per request, and the reader should see it once.
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable(),
              let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount),
              let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              let oxygenType = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation),
              let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitBridgeError.unavailable
        }
        let effortTypes = EffortMeasure.allCases.compactMap {
            HKQuantityType.quantityType(forIdentifier: $0.identifier) as HKObjectType?
        }
        try await store.requestAuthorization(
            toShare: Set([stepsType, sleepType, heartRateType, oxygenType] as [HKSampleType] + workoutShareTypes),
            read: Set([stepsType, sleepType] as [HKObjectType] + effortTypes)
        )
    }

    /// A workout, and the samples that carry what it cost: HealthKit derives a
    /// workout's totals from the samples attached to it.
    private var workoutShareTypes: [HKSampleType] {
        [HKObjectType.workoutType() as HKSampleType]
            + [HKQuantityTypeIdentifier.activeEnergyBurned, .distanceWalkingRunning]
                .compactMap { HKQuantityType.quantityType(forIdentifier: $0) }
    }

    func synchronize(
        _ samples: [WatchHealthSample],
        authorization: Authorization = .mayAsk
    ) async throws {
        guard HKHealthStore.isHealthDataAvailable(),
              let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount),
              let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              let oxygenType = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation),
              let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitBridgeError.unavailable
        }
        switch authorization {
        case .mayAsk:
            try await store.requestAuthorization(
                toShare: Set([stepsType, sleepType, heartRateType, oxygenType] as [HKSampleType] + workoutShareTypes),
                read: [stepsType, sleepType]
            )
        case .onlyWhatIsAlreadyGranted:
            // Writing is the one side HealthKit lets an app read back. Any
            // one type allowed is enough: the rest are skipped below.
            let types: [HKObjectType] = [stepsType, sleepType, heartRateType, oxygenType, .workoutType()]
            guard types.contains(where: { store.authorizationStatus(for: $0) == .sharingAuthorized }) else {
                throw HealthKitBridgeError.notGranted
            }
        }
        // The reader may allow steps and refuse the heart: HealthKit's sheet
        // takes them separately. Skipping just the refused type keeps the rest
        // flowing rather than failing the whole export.
        let mayWrite: [ExportKind: Bool] = [
            .steps: store.authorizationStatus(for: stepsType) == .sharingAuthorized,
            .sleep: store.authorizationStatus(for: sleepType) == .sharingAuthorized,
            .heartRate: store.authorizationStatus(for: heartRateType) == .sharingAuthorized,
            .workouts: store.authorizationStatus(for: .workoutType()) == .sharingAuthorized,
            .bloodOxygen: store.authorizationStatus(for: oxygenType) == .sharingAuthorized,
        ]
        let watchSamples = samples.filter { $0.source != .healthKit }
        func owed(_ kind: ExportKind, _ sample: WatchHealthSample) -> Bool {
            mayWrite[kind] == true && sample.updatedAt > exportCursor(kind)
        }
        var exportedThrough: [ExportKind: Date] = [:]
        func exported(_ kind: ExportKind, _ sample: WatchHealthSample) {
            exportedThrough[kind] = max(exportedThrough[kind] ?? .distantPast, sample.updatedAt)
        }
        var healthSamples: [HKSample] = []
        var outgrownSleepIdentifiers: [String] = []
        var workoutWrites: [(workout: WatchWorkout, metadata: [String: Any])] = []
        for sample in watchSamples {
            let version = max(1, Int(sample.updatedAt.timeIntervalSince1970))
            let baseIdentifier = "pebble.\(sample.id.uuidString.lowercased())"
            let commonMetadata: [String: Any] = [
                HKMetadataKeyExternalUUID: sample.id.uuidString,
                HKMetadataKeySyncVersion: version,
            ]
            if owed(.steps, sample) {
                exported(.steps, sample)
                var stepsMetadata = commonMetadata
                stepsMetadata[HKMetadataKeySyncIdentifier] = "\(baseIdentifier).steps"
                healthSamples.append(HKQuantitySample(
                    type: stepsType,
                    quantity: HKQuantity(unit: .count(), doubleValue: Double(sample.steps)),
                    start: sample.date,
                    end: sample.date.addingTimeInterval(60),
                    metadata: stepsMetadata
                ))
            }
            if owed(.sleep, sample), !sample.sleepSessions.isEmpty {
                exported(.sleep, sample)
                // The night as the watch measured it: real start and end, the
                // nap as its own block, and the deep stretches as the stage
                // they are. The synthetic block below misplaces all three.
                // A day this app once exported as one synthetic block keeps
                // that block even as the segments arrive — the identifiers
                // differ, so nothing replaces it and the night counts twice.
                outgrownSleepIdentifiers.append("\(baseIdentifier).sleep")
                for session in sample.sleepSessions {
                    for segment in session.stageSegments {
                        var sleepMetadata = commonMetadata
                        sleepMetadata[HKMetadataKeySyncIdentifier] =
                            "\(baseIdentifier).sleep.\(Int(segment.start.timeIntervalSince1970))"
                        healthSamples.append(HKCategorySample(
                            type: sleepType,
                            value: (segment.isDeep
                                ? HKCategoryValueSleepAnalysis.asleepDeep
                                : HKCategoryValueSleepAnalysis.asleepUnspecified).rawValue,
                            start: segment.start,
                            end: segment.end,
                            metadata: sleepMetadata
                        ))
                    }
                }
            } else if owed(.sleep, sample), sample.sleepMinutes > 0 {
                exported(.sleep, sample)
                // A record from before sessions were kept knows only the
                // total, so the block is synthetic — anchored to the day, not
                // to when anybody slept.
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
            if owed(.workouts, sample) {
                exported(.workouts, sample)
                for workout in sample.workouts where workout.duration > 0 {
                    var workoutMetadata = commonMetadata
                    workoutMetadata[HKMetadataKeySyncIdentifier] =
                        "\(baseIdentifier).workout.\(Int(workout.start.timeIntervalSince1970))"
                    workoutWrites.append((workout, workoutMetadata))
                }
            }
            if owed(.heartRate, sample) {
                exported(.heartRate, sample)
                // One sample per measured minute, at the minute it was
                // measured — a day's average written as one sample would sit
                // among real readings and bend every chart it touches.
                for reading in sample.heartRateReadings {
                    var heartRateMetadata = commonMetadata
                    heartRateMetadata[HKMetadataKeySyncIdentifier] =
                        "\(baseIdentifier).hr.\(Int(reading.date.timeIntervalSince1970))"
                    healthSamples.append(HKQuantitySample(
                        type: heartRateType,
                        quantity: HKQuantity(
                            unit: .count().unitDivided(by: .minute()),
                            doubleValue: Double(reading.beatsPerMinute)
                        ),
                        start: reading.date,
                        end: reading.date.addingTimeInterval(60),
                        metadata: heartRateMetadata
                    ))
                }
            }
            if owed(.bloodOxygen, sample) {
                exported(.bloodOxygen, sample)
                for reading in sample.bloodOxygenReadings {
                    var oxygenMetadata = commonMetadata
                    oxygenMetadata[HKMetadataKeySyncIdentifier] =
                        "\(baseIdentifier).spo2.\(Int(reading.date.timeIntervalSince1970))"
                    // HealthKit keeps oxygen saturation as a fraction of one; the
                    // watch reports whole percent, so 97% is written as 0.97.
                    healthSamples.append(HKQuantitySample(
                        type: oxygenType,
                        quantity: HKQuantity(unit: .percent(), doubleValue: Double(reading.percent) / 100),
                        start: reading.date,
                        end: reading.date.addingTimeInterval(60),
                        metadata: oxygenMetadata
                    ))
                }
            }
        }
        if !outgrownSleepIdentifiers.isEmpty {
            // HealthKit only lets an app delete what it wrote itself, which is
            // exactly the reach this needs. A day never exported the old way
            // simply has nothing to delete.
            try await deleteOwnObjects(
                of: sleepType,
                predicate: HKQuery.predicateForObjects(
                    withMetadataKey: HKMetadataKeySyncIdentifier,
                    allowedValues: outgrownSleepIdentifiers
                )
            )
        }
        for (workout, metadata) in workoutWrites {
            try await saveWorkout(workout, metadata: metadata)
        }
        if !healthSamples.isEmpty {
            try await store.save(healthSamples)
        }
        // Only after everything reached HealthKit: a cursor moved before a
        // failed save would strand what the save dropped.
        for (kind, through) in exportedThrough {
            advanceExportCursor(kind, to: through)
        }
    }

    /// One watch workout as HealthKit takes it: a builder over the workout's
    /// real span, with the distance and active energy attached as samples —
    /// that is where a workout's totals come from since iOS 17 retired the
    /// total-carrying initializers.
    private func saveWorkout(_ workout: WatchWorkout, metadata: [String: Any]) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = switch workout.kind {
        case .walk: .walking
        case .run: .running
        case .open: .other
        }
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: nil)
        try await builder.beginCollection(at: workout.start)
        try await builder.addMetadata(metadata)
        // The attached samples get identifiers of their own: replacing the
        // workout on a re-export replaces the workout object, and a distance
        // left without one would stay behind and count twice.
        func attachedMetadata(_ suffix: String) -> [String: Any] {
            var value = metadata
            value[HKMetadataKeySyncIdentifier] = (metadata[HKMetadataKeySyncIdentifier] as? String ?? "") + suffix
            return value
        }
        var attached: [HKSample] = []
        if workout.distanceMetres > 0,
           let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
           store.authorizationStatus(for: distanceType) == .sharingAuthorized {
            attached.append(HKQuantitySample(
                type: distanceType,
                quantity: HKQuantity(unit: .meter(), doubleValue: Double(workout.distanceMetres)),
                start: workout.start,
                end: workout.end,
                metadata: attachedMetadata(".distance")
            ))
        }
        if workout.activeKilocalories > 0,
           let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
           store.authorizationStatus(for: energyType) == .sharingAuthorized {
            attached.append(HKQuantitySample(
                type: energyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(workout.activeKilocalories)),
                start: workout.start,
                end: workout.end,
                metadata: attachedMetadata(".energy")
            ))
        }
        if !attached.isEmpty {
            try await builder.addSamples(attached)
        }
        try await builder.endCollection(at: workout.end)
        try await builder.finishWorkout()
    }

    private func deleteOwnObjects(of type: HKObjectType, predicate: NSPredicate) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.deleteObjects(of: type, predicate: predicate) { _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
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

    func readRecentSamples(days: Int = 90) async throws -> [WatchHealthSample] {
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
        // Summed as they come and rounded once at the end: an Apple Watch
        // writes its energy a fraction of a kilocalorie at a time, and cutting
        // each sample to a whole number first left a day's total near zero.
        var stepsBySource: [Date: [String: Double]] = [:]
        var sleepBySource: [Date: [String: Double]] = [:]
        var updatedAtByDay: [Date: Date] = [:]
        for case let sample as HKQuantitySample in try await stepSamples {
            guard !(sample.metadata?[HKMetadataKeySyncIdentifier] as? String ?? "").hasPrefix("pebble.") else { continue }
            let day = Calendar.current.startOfDay(for: sample.startDate)
            let source = sample.sourceRevision.source.bundleIdentifier
            stepsBySource[day, default: [:]][source, default: 0] += sample.quantity.doubleValue(for: .count())
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
            sleepBySource[day, default: [:]][source, default: 0] += sample.endDate.timeIntervalSince(sample.startDate) / 60
            updatedAtByDay[day] = max(updatedAtByDay[day] ?? .distantPast, sample.endDate)
        }
        var effortBySource: [EffortMeasure: [Date: [String: Double]]] = [:]
        for (measure, type) in effortTypes {
            for case let sample as HKQuantitySample in try await query(type: type, start: start, end: end) {
                // The watch's own workouts come back on these types too now,
                // and reading them here would send the watch its own numbers.
                guard !(sample.metadata?[HKMetadataKeySyncIdentifier] as? String ?? "").hasPrefix("pebble.") else { continue }
                let day = Calendar.current.startOfDay(for: sample.startDate)
                let source = sample.sourceRevision.source.bundleIdentifier
                effortBySource[measure, default: [:]][day, default: [:]][source, default: 0]
                    += sample.quantity.doubleValue(for: measure.unit)
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
            func whole(_ bySource: [String: Double]?) -> Int {
                Int((bySource?.values.max() ?? 0).rounded())
            }
            func effort(_ measure: EffortMeasure) -> Int {
                whole(effortBySource[measure]?[day])
            }
            return WatchHealthSample(
                date: day,
                steps: whole(stepsBySource[day]),
                sleepMinutes: min(24 * 60, whole(sleepBySource[day])),
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
