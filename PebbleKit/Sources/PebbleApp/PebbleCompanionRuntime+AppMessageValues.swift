import PebbleProtocol
import Foundation
import WebKit

extension PebbleCompanionRuntime {
    func resolve(callbackID: Int, succeeded: Bool, page: WKWebView) async throws {
        guard let webView, webView === page else { throw CompanionRuntimeError.noApplicationLoaded }
        _ = try await webView.callAsyncJavaScript(
            "window.__pebbleResult(id, ok);",
            arguments: ["id": callbackID, "ok": succeeded],
            in: nil,
            contentWorld: .page
        )
    }

    /// A script's value as a tuple, in the official runtime's order
    /// (`PKJSApp.kt` `toAppMessageData`): a string, then a whole number that
    /// fits a signed 32-bit integer as signed, a larger one as unsigned, and
    /// a fraction cut toward zero. Everything non-negative as unsigned was the
    /// same bytes but another tuple type, which an app checking
    /// `tuple->type == TUPLE_INT` refuses.
    static func appMessageValue(_ value: Any) -> AppMessageValue? {
        switch value {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            let number = value.doubleValue
            guard number.isFinite else { return nil }
            let whole = number.rounded(.towardZero)
            if let signed = Int32(exactly: whole) { return .signed(signed) }
            if whole == number, let long = Int64(exactly: whole) {
                return .unsigned(UInt32(truncatingIfNeeded: long))
            }
            return .signed(whole < 0 ? .min : .max)
        case let values as [Any]:
            // Wrapped per byte, as `toUByte()` does: casting the array to
            // `[UInt8]` failed on one element out of range and lost the tuple.
            var bytes: [UInt8] = []
            for element in values {
                guard let number = (element as? NSNumber)?.doubleValue,
                      let long = Int64(exactly: number) else { return nil }
                bytes.append(UInt8(truncatingIfNeeded: long))
            }
            return .bytes(bytes)
        default:
            return nil
        }
    }

    func javaScriptValue(_ value: AppMessageValue) -> Any {
        switch value {
        case .bytes(let bytes): bytes
        case .string(let string): string
        case .unsigned(let number): number
        case .signed(let number): number
        }
    }
}
