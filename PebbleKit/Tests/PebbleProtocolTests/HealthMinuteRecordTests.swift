import Foundation
import Testing
@testable import PebbleProtocol

/// One data-logging minute record, read the way the watch wrote it.
///
/// The layout is `AlgMinuteDLSRecord` in PebbleOS
/// `include/pbl/services/activity/activity_algorithm.h`: a nine-byte header,
/// then `num_samples` samples of `sample_size` bytes each. Inside a sample,
/// byte 0 is the steps and byte 12 the heart rate, added in version 7.
@Suite
struct HealthMinuteRecordTests {
    /// `AlgMinuteRecordHdr` followed by its samples, in the frame
    /// `HealthDataLoggingProcessor` opens a session for.
    private func minuteRecord(
        version: UInt16,
        sampleSize: Int,
        startingAt timestamp: UInt32,
        samples: [[UInt8]]
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes += [UInt8(version & 0xFF), UInt8(version >> 8)]
        bytes += (0..<4).map { UInt8((timestamp >> (8 * UInt32($0))) & 0xFF) }
        bytes += [0]                        // time_local_offset_15_min
        bytes += [UInt8(sampleSize)]        // sample_size
        bytes += [UInt8(samples.count)]     // num_samples
        for sample in samples {
            var padded = sample
            padded += [UInt8](repeating: 0, count: max(0, sampleSize - sample.count))
            bytes += padded.prefix(sampleSize)
        }
        return bytes
    }

    /// A minute with steps and, from byte 12, a heart rate.
    private func minute(steps: UInt8, heartRate: UInt8?) -> [UInt8] {
        var sample = [UInt8](repeating: 0, count: 16)
        sample[0] = steps
        if let heartRate { sample[12] = heartRate }
        return sample
    }

    private func samples(
        version: UInt16,
        sampleSize: Int,
        minutes: [[UInt8]]
    ) throws -> [WatchHealthSample] {
        var processor = HealthDataLoggingProcessor()
        let sessionID: UInt8 = 7
        let record = minuteRecord(
            version: version,
            sampleSize: sampleSize,
            startingAt: 1_757_000_000,
            samples: minutes
        )

        // The session's own header: a tag of 81 at byte 22, which is the one
        // step records arrive on, and the size of one whole record at byte 27 —
        // header and samples together, which is what the decoder strides by.
        var open = [UInt8](repeating: 0, count: 29)
        open[0] = 0x01
        open[1] = sessionID
        open[22] = 81
        open[27] = UInt8(record.count & 0xFF)
        open[28] = UInt8(record.count >> 8)
        _ = try processor.process(PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: open))
        var data: [UInt8] = [0x02, sessionID]
        data += [UInt8](repeating: 0, count: 8)
        data += record
        return try processor.process(
            PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: data)
        ).samples
    }

    /// Version 13 is what the firmware sends today.
    @Test func aHeartRateIsReadFromByteTwelve() throws {
        let read = try samples(
            version: 13,
            sampleSize: 16,
            minutes: [minute(steps: 10, heartRate: 60), minute(steps: 20, heartRate: 80)]
        )

        let day = try #require(read.first)
        #expect(day.steps == 30)
        #expect(day.heartRate?.lowest == 60)
        #expect(day.heartRate?.highest == 80)
        #expect(day.heartRate?.average == 70)
        #expect(day.heartRate?.measuredMinutes == 2)
    }

    /// Zero is the watch saying it did not measure, and averaging it in would
    /// halve the day.
    @Test func aMinuteWithNoReadingIsNotAHeartRateOfZero() throws {
        let read = try samples(
            version: 13,
            sampleSize: 16,
            minutes: [minute(steps: 1, heartRate: 60), minute(steps: 1, heartRate: nil)]
        )

        #expect(try #require(read.first).heartRate?.average == 60)
        #expect(try #require(read.first).heartRate?.measuredMinutes == 1)
    }

    /// Nil rather than a summary of zeroes, so a day nothing measured can be
    /// told apart from a day it measured zero.
    @Test func aDayWithNothingMeasuredHasNoHeartRateAtAll() throws {
        let read = try samples(
            version: 13,
            sampleSize: 16,
            minutes: [minute(steps: 5, heartRate: nil)]
        )

        #expect(try #require(read.first).steps == 5)
        #expect(try #require(read.first).heartRate == nil)
    }

    /// Before version 7 the byte is not a heart rate, and the sample is not
    /// long enough to hold one.
    @Test func aVersionOlderThanSevenCarriesNoHeartRate() throws {
        var sixByteMinute = [UInt8](repeating: 0, count: 6)
        sixByteMinute[0] = 12

        let read = try samples(version: 5, sampleSize: 6, minutes: [sixByteMinute])

        #expect(try #require(read.first).steps == 12)
        #expect(try #require(read.first).heartRate == nil)
    }

    /// Version 12 exists and version 8 does not. The list this used to check
    /// against had it the other way round, so a watch on 12 lost its day (#112).
    @Test func aVersionTheOldListLeftOutIsStillRead() throws {
        let read = try samples(
            version: 12,
            sampleSize: 15,
            minutes: [minute(steps: 40, heartRate: 55)]
        )

        #expect(try #require(read.first).steps == 40)
        #expect(try #require(read.first).heartRate?.average == 55)
    }

    /// The firmware promises only to append, so a version added after this was
    /// written parses on the fields it already knows.
    @Test func aVersionFromTheFutureIsReadRatherThanDropped() throws {
        var longerMinute = minute(steps: 7, heartRate: 65)
        longerMinute += [UInt8](repeating: 0xFF, count: 4)

        let read = try samples(version: 20, sampleSize: 20, minutes: [longerMinute])

        #expect(try #require(read.first).steps == 7)
        #expect(try #require(read.first).heartRate?.average == 65)
    }
}
