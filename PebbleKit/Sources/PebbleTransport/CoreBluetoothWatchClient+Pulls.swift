public import PebbleProtocol
import CoreBluetooth
import Foundation

/// The three longer answers the watch is asked for: a screenshot, a generation
/// of logs, a file off its flash.
///
/// They differ only in which collector reads the pieces and how long the watch
/// may go quiet, which is why they are one `pull(_:)` and one file. The
/// `WatchPull` machinery that waits for them is in `WatchPull.swift`.
extension CoreBluetoothWatchClient {
    public func pull(_ request: WatchPullRequest) async throws -> WatchPullAnswer {
        let peripheral = try linkedPeripheral()
        switch request {
        case .screenshot:
            return .screenshot(try await screenshot.run(collecting: ScreenshotCollector()) {
                try sendFrame(ScreenshotCodec.requestFrame(), to: peripheral)
            })

        case .logGeneration(let generation):
            let cookie = nextLogDumpCookie
            nextLogDumpCookie &+= 1
            let dump = try await logDump.run(collecting: LogDumpCollector(cookie: cookie)) {
                try sendFrame(
                    LogDumpCodec.requestFrame(generation: generation, cookie: cookie),
                    to: peripheral
                )
            }
            switch dump {
            case .lines(let lines): return .logLines(lines)
            case .noLogs: return .logLines(nil)
            }

        case .file(let fileRequest):
            let transactionID = nextGetBytesTransactionID
            nextGetBytesTransactionID &+= 1
            return .bytes(try await fileBytes.run(
                collecting: GetBytesCollector(transactionID: transactionID)
            ) {
                try sendFrame(
                    GetBytesCodec.requestFrame(fileRequest, transactionID: transactionID),
                    to: peripheral
                )
            })
        }
    }

    func failPulls(_ error: any Error) {
        screenshot.finish(.failure(error))
        logDump.finish(.failure(error))
        fileBytes.finish(.failure(error))
    }
}
