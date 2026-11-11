import Foundation
@main struct WidgetFeedParsingTests {
    static func main() throws {
        let place: [String: Any] = ["name": "Fixture"]
        func forecast(_ current: Double, high: Double = 72, low: Double? = 48,
                      hours: [Double] = [61, 62]) -> [String: Any] {
            ["current": ["temperature_2m": current, "relative_humidity_2m": 42],
             "daily": ["temperature_2m_max": [high], "temperature_2m_min": low.map { [$0] } ?? []],
             "hourly": ["time": ["2026-11-10T12:00", "2026-11-10T13:00"],
                        "temperature_2m": hours, "weather_code": [0, 1]]]
        }
        let normal = try WidgetFeeds.weather(place: place, forecast: forecast(61.6), fallbackCity: "Other")
        precondition(normal.weather?.temperature == 62 && normal.weather?.high == 72)
        precondition(normal.weather?.hours.map(\.temperature) == [61, 62])
        for value in [Double.infinity, -.infinity, .nan, Double.greatestFiniteMagnitude] {
            do {
                _ = try WidgetFeeds.weather(place: place, forecast: forecast(value), fallbackCity: "Other")
                preconditionFailure("Invalid current temperature accepted")
            } catch WidgetFeedError.badResponse { }
            let partial = try WidgetFeeds.weather(place: place,
                forecast: forecast(60, high: value, hours: [value, 62]), fallbackCity: "Other")
            precondition(partial.weather?.high == nil && partial.weather?.hours.map(\.temperature) == [62])
        }
        let missingLow = try WidgetFeeds.weather(place: place, forecast: forecast(60, low: nil), fallbackCity: "Other")
        precondition(missingLow.weather?.low == nil && !missingLow.lines.contains { $0.contains("L:") })
        print("PASS: weather rounding, missing daily values, invalid and overflowing temperatures never crash")
    }
}
