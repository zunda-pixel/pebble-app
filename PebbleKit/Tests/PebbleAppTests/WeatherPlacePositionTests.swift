import Foundation
import Testing
@testable import PebbleApp

/// A weather place is either the phone's position or a fixed pair — not
/// coordinates plus a flag. The flag shape persisted a snapshot of wherever
/// the phone was when the row was added, and a failed location read silently
/// served that stale place as "Current Location" (#122).
@Suite
struct WeatherPlacePositionTests {
    @Test func aFixedPlaceRoundTrips() throws {
        let place = WeatherPlace(
            id: UUID(),
            name: "Kyoto",
            position: .fixed(latitude: 35.01, longitude: 135.76)
        )

        let reopened = try JSONDecoder().decode(
            WeatherPlace.self,
            from: try JSONEncoder().encode(place)
        )

        #expect(reopened == place)
    }

    /// The row written before positions existed still opens, keeping what was
    /// real in it.
    @Test func aLegacyFixedRowKeepsItsCoordinates() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Kyoto",
         "latitude":35.01,"longitude":135.76,"followsPhone":false}
        """
        let place = try JSONDecoder().decode(WeatherPlace.self, from: Data(json.utf8))

        #expect(place.position == .fixed(latitude: 35.01, longitude: 135.76))
        #expect(!place.followsPhone)
    }

    /// And the phone-following row drops its snapshot: those numbers are
    /// wherever the phone was the day the row was added, which is exactly the
    /// stale fallback the variant exists to end.
    @Test func aLegacyPhoneRowDropsItsSnapshot() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Current Location",
         "latitude":35.68,"longitude":139.76,"followsPhone":true}
        """
        let place = try JSONDecoder().decode(WeatherPlace.self, from: Data(json.utf8))

        #expect(place.position == .phone)

        // Nothing to fall back on survives the rewrite.
        let rewritten = String(decoding: try JSONEncoder().encode(place), as: UTF8.self)
        #expect(!rewritten.contains("latitude"))
        #expect(!rewritten.contains("35.68"))
    }
}
