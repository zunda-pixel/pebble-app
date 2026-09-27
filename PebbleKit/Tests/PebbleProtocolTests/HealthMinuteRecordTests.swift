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
        localOffsetQuarters: Int8 = 0,
        samples: [[UInt8]]
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes += [UInt8(version & 0xFF), UInt8(version >> 8)]
        bytes += (0..<4).map { UInt8((timestamp >> (8 * UInt32($0))) & 0xFF) }
        bytes += [UInt8(bitPattern: localOffsetQuarters)]   // time_local_offset_15_min
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

    /// An 18-byte minute with steps, heart rate (byte 12) and, from byte 16, the
    /// SpO2 percentage added in version 14.
    private func minute(steps: UInt8, heartRate: UInt8?, spo2: UInt8?) -> [UInt8] {
        var sample = [UInt8](repeating: 0, count: 18)
        sample[0] = steps
        if let heartRate { sample[12] = heartRate }
        if let spo2 { sample[16] = spo2 }
        return sample
    }

    private func samples(
        version: UInt16,
        sampleSize: Int,
        localOffsetQuarters: Int8 = 0,
        minutes: [[UInt8]]
    ) throws -> [WatchHealthSample] {
        var processor = HealthDataLoggingProcessor()
        let sessionID: UInt8 = 7
        let record = minuteRecord(
            version: version,
            sampleSize: sampleSize,
            startingAt: 1_757_000_000,
            localOffsetQuarters: localOffsetQuarters,
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

    /// Version 14 appends SpO2 at byte 16. Zero is "not measured this minute",
    /// the same as the heart rate, and each measured minute keeps its moment.
    @Test func bloodOxygenIsReadFromByteSixteen() throws {
        let read = try samples(
            version: 14,
            sampleSize: 18,
            minutes: [
                minute(steps: 10, heartRate: 60, spo2: 97),
                minute(steps: 5, heartRate: nil, spo2: nil),
                minute(steps: 20, heartRate: 80, spo2: 95),
            ]
        )

        let day = try #require(read.first)
        #expect(day.bloodOxygen?.lowest == 95)
        #expect(day.bloodOxygen?.highest == 97)
        #expect(day.bloodOxygen?.average == 96)
        #expect(day.bloodOxygen?.measuredMinutes == 2)
        #expect(day.bloodOxygenReadings.map(\.percent) == [97, 95])
    }

    /// Before version 14 byte 16 is not SpO2, so a record that old carries none.
    @Test func aVersionOlderThanFourteenCarriesNoBloodOxygen() throws {
        let read = try samples(
            version: 13,
            sampleSize: 16,
            minutes: [minute(steps: 10, heartRate: 60)]
        )

        #expect(try #require(read.first).bloodOxygen == nil)
    }

    /// Each measured minute keeps its moment: the HealthKit export writes them
    /// back as per-minute samples, which a day summary could not honestly
    /// become. The unmeasured minute between them is absent, not zero.
    @Test func theMeasuredMinutesKeepTheirMoments() throws {
        let read = try samples(
            version: 13,
            sampleSize: 16,
            minutes: [
                minute(steps: 10, heartRate: 60),
                minute(steps: 5, heartRate: nil),
                minute(steps: 20, heartRate: 80),
            ]
        )

        let day = try #require(read.first)
        #expect(day.heartRateReadings.map(\.beatsPerMinute) == [60, 80])
        #expect(day.heartRateReadings.map(\.date) == [
            Date(timeIntervalSince1970: 1_757_000_000),
            Date(timeIntervalSince1970: 1_757_000_120),
        ])
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

    /// 1_757_000_000 is 15:33 UTC on 4 September 2025, which is already the
    /// 5th in Tokyo and still the 4th in California. The day is the watch's.
    @Test(arguments: [
        (Int8(36), TimeInterval(1_756_998_000)),    // UTC+9: from 15:00 UTC on the 4th
        (Int8(-28), TimeInterval(1_756_969_200)),   // UTC−7: from 07:00 UTC on the 4th
    ])
    func aMinutesDayIsTheOneOnTheWatchsClock(offset: Int8, startOfDay: TimeInterval) throws {
        let read = try samples(
            version: 13,
            sampleSize: 16,
            localOffsetQuarters: offset,
            minutes: [minute(steps: 10, heartRate: nil)]
        )

        let day = try #require(read.first)
        #expect(day.date == Date(timeIntervalSince1970: startOfDay))
        #expect(TimeZone(identifier: day.timeZoneIdentifier)?.secondsFromGMT() == Int(offset) * 15 * 60)
    }

    /// Steps and the night that ended in the same minute land on one day, both
    /// counted in the zone the watch was in — the phone's own zone put the
    /// steps a day away from the sleep for anyone travelling.
    @Test func stepsAndSleepAreFiledUnderTheSameDay() throws {
        let steps = try #require(try samples(
            version: 13,
            sampleSize: 16,
            localOffsetQuarters: 36,
            minutes: [minute(steps: 10, heartRate: nil)]
        ).first)

        var processor = HealthDataLoggingProcessor()
        var open = [UInt8](repeating: 0, count: 29)
        open[0] = 0x01
        open[1] = 3
        open[22] = 83
        open[27] = 18
        _ = try processor.process(PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: open))
        // `ActivitySessionDataLoggingRecord`: type 1 (sleep) at byte 4, the
        // seconds east of UTC at 6, the start at 10 and the length at 14.
        let night: [UInt8] = [0, 0, 0, 0]
            + UInt16(1).littleEndianBytes
            + Int32(9 * 3_600).littleEndianBytes
            + UInt32(1_757_000_000 - 3_600).littleEndianBytes
            + UInt32(3_600).littleEndianBytes
        let data: [UInt8] = [0x02, 3] + [UInt8](repeating: 0, count: 8) + night
        let sleep = try #require(try processor.process(
            PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: data)
        ).samples.first)

        #expect(sleep.date == steps.date)
        #expect(
            TimeZone(identifier: sleep.timeZoneIdentifier)?.secondsFromGMT()
                == TimeZone(identifier: steps.timeZoneIdentifier)?.secondsFromGMT()
        )
    }
}

/// Which sessions are minute data, and which only look like it.
///
/// Measured on the test watch (Pebble Time 2, v4.36.2) on 2026-09-09: every
/// connect opens two sessions, tag 81 and tag 85. The tag-85 one is protobuf —
/// its first bytes are `12 0c` and then the watch's serial — and reading it as
/// minute records filed a day in 1996 with whatever byte 0 of each 97-byte
/// stretch happened to be.
@Suite
struct HealthDataLoggingTagTests {
    private func session(tag: UInt8, itemSize: Int) -> [UInt8] {
        var open = [UInt8](repeating: 0, count: 29)
        open[0] = 0x01
        open[1] = 1
        open[22] = tag
        open[27] = UInt8(itemSize & 0xFF)
        open[28] = UInt8(itemSize >> 8)
        return open
    }

    /// The first bytes of a real tag-85 session, as captured from the watch.
    private let protobufLog: [UInt8] = [
        0x63, 0x68, 0x12, 0x0c, 0x43, 0x31, 0x31, 0x31, 0x32, 0x38, 0x31, 0x31,
        0x30, 0x33, 0x35, 0x56, 0x2a, 0x09, 0x20, 0x04, 0x28, 0x25, 0x32, 0x03,
        0x30, 0x2d, 0x30, 0x18, 0xb6, 0xc8, 0x80, 0xd5, 0x06, 0x62, 0xf8, 0x01,
    ]

    @Test func aProtobufLogSessionIsNotReadAsSteps() throws {
        var processor = HealthDataLoggingProcessor()
        _ = try processor.process(
            PebbleProtocolFrame(
                endpoint: HealthDataLoggingCodec.endpoint,
                payload: session(tag: 85, itemSize: protobufLog.count)
            )
        )

        var data: [UInt8] = [0x02, 1]
        data += [UInt8](repeating: 0, count: 8)
        data += protobufLog
        let result = try processor.process(
            PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: data)
        )

        // Taken and acknowledged, as any tag this app has no use for is, and
        // nothing invented from it.
        #expect(result.samples.isEmpty)
        #expect(result.response != nil)
    }
}
