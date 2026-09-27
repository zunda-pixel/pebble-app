import CoreLocation
import PebbleProtocol
import Foundation
import WebKit

extension PebbleCompanionRuntime {
    /// Follows the phone's position for a script's `watchPosition`, delivering
    /// every fix into the same callback until `clearWatch` or the page's end.
    func startPositionWatcher(requestID: Int, page: WKWebView) {
        positionWatchers.removeValue(forKey: requestID)?.cancel()
        positionWatchers[requestID] = Task { [weak self, weak page] in
            do {
                guard let updates = try self?.locationUpdatesHandler() else { return }
                await DiagnosticLog.shared.record(
                    category: "configuration",
                    message: "a script is watching the position (watch \(requestID))"
                )
                // The first fix, straight away: the live stream can take
                // seconds to warm up, and the single-shot path already holds a
                // recent one. A script's first paint should not wait on GPS.
                if let seed = try? await self?.locationHandler() {
                    guard !Task.isCancelled, let page else { return }
                    await self?.deliverPosition(
                        requestID: requestID,
                        page: page,
                        position: Self.webPosition(seed),
                        error: nil
                    )
                }
                var delivered = 0
                for try await location in updates {
                    guard !Task.isCancelled, let page else { return }
                    await self?.deliverPosition(
                        requestID: requestID,
                        page: page,
                        position: Self.webPosition(location),
                        error: nil
                    )
                    delivered += 1
                    if delivered == 1 {
                        await DiagnosticLog.shared.record(
                            category: "configuration",
                            message: "the watched position delivered its first live fix (watch \(requestID))"
                        )
                    }
                }
                await DiagnosticLog.shared.record(
                    category: "configuration",
                    message: "the position stream ended (watch \(requestID), \(delivered) live fixes)"
                )
            } catch {
                guard !Task.isCancelled, let page else { return }
                await self?.deliverPosition(
                    requestID: requestID,
                    page: page,
                    position: nil,
                    error: Self.webPositionError(error)
                )
                await DiagnosticLog.shared.record(
                    .warning,
                    category: "configuration",
                    message: "a watched position failed (watch \(requestID)): \(String(reflecting: error))"
                )
            }
        }
    }

    /// The page is going or gone: nobody is left to deliver positions to.
    func cancelPositionWatchers() {
        for watcher in positionWatchers.values { watcher.cancel() }
        positionWatchers = [:]
    }

    /// Answers a script's request for a position, in the shape the web has for
    /// one so that a script written against a browser reads it unchanged.
    func answerPosition(requestID: Int, page: WKWebView) async {
        do {
            let location = try await locationHandler()
            await deliverPosition(requestID: requestID, page: page, position: Self.webPosition(location), error: nil)
        } catch {
            await deliverPosition(requestID: requestID, page: page, position: nil, error: Self.webPositionError(error))
            await DiagnosticLog.shared.record(
                .warning,
                category: "configuration",
                message: "an application asked for a position and did not get one:"
                    + " \(String(reflecting: error))"
            )
        }
    }

    /// The page that asked, not whichever page is up now: a page built since
    /// numbers its requests from one again, and would take the answer to
    /// another page's question as the answer to its own.
    func deliverPosition(
        requestID: Int,
        page: WKWebView,
        position: [String: Any]?,
        error: [String: Any]?
    ) async {
        guard let webView, webView === page else { return }
        _ = try? await webView.callAsyncJavaScript(
            "window.__pebblePosition(id, position, error);",
            arguments: [
                "id": requestID,
                "position": position as Any,
                "error": error as Any,
            ],
            in: nil,
            contentWorld: .page
        )
    }

    /// A `CLLocation` as a `GeolocationPosition`.
    ///
    /// CoreLocation says "I do not know" with a negative number, and the web
    /// says it with null; passing the negative through would have a script
    /// draw a heading of -1 degrees.
    static func webPosition(_ location: CLLocation) -> [String: Any] {
        func known(_ value: CLLocationDistance) -> Any {
            value < 0 ? NSNull() : value
        }
        return [
            "coords": [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "accuracy": known(location.horizontalAccuracy),
                "altitude": location.verticalAccuracy < 0 ? NSNull() as Any : location.altitude as Any,
                "altitudeAccuracy": known(location.verticalAccuracy),
                "heading": known(location.course),
                "speed": known(location.speed),
            ],
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000,
        ]
    }

    /// A `GeolocationPositionError`. The codes are the web's: 1 refused, 2
    /// could not be found, 3 took too long. Refused is the one worth telling
    /// apart — the reader can do something about it, and the others they
    /// cannot.
    static func webPositionError(_ error: any Error) -> [String: Any] {
        let refused = (error as? WeatherSourceError) == .locationNotAllowed
        return [
            "code": refused ? 1 : 2,
            "message": refused
                ? "Pebble has not been allowed your position."
                : "Your position could not be found.",
        ]
    }
}
