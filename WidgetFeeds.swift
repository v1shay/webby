import Foundation

struct WidgetFeed {
    let subtitle: String
    let lines: [String]
    var chart: [Double] = []
}

enum WidgetFeedError: LocalizedError {
    case noResults, badResponse, provider(String)

    var errorDescription: String? {
        switch self {
        case .noResults: "No results found"
        case .badResponse: "The data source did not return usable data"
        case .provider(let message): message
        }
    }
}

enum WidgetFeeds {
    static func weather(city: String) async throws -> WidgetFeed {
        var search = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        search.queryItems = [URLQueryItem(name: "name", value: city),
                             URLQueryItem(name: "count", value: "1"),
                             URLQueryItem(name: "language", value: "en")]
        let locations = try await json(search.url!)
        guard let place = (locations["results"] as? [[String: Any]])?.first,
              let latitude = place["latitude"] as? Double,
              let longitude = place["longitude"] as? Double else { throw WidgetFeedError.noResults }
        var query = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        query.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        let forecast = try await json(query.url!)
        let current = forecast["current"] as? [String: Any] ?? [:]
        let daily = forecast["daily"] as? [String: Any] ?? [:]
        let temperature = current["temperature_2m"] as? Double
        let humidity = current["relative_humidity_2m"] as? Int
        let highs = daily["temperature_2m_max"] as? [Double] ?? []
        let lows = daily["temperature_2m_min"] as? [Double] ?? []
        let name = place["name"] as? String ?? city
        return WidgetFeed(subtitle: name,
                          lines: [temperature.map { "Now  \(Int($0.rounded()))°F" } ?? "Current temperature unavailable",
                                  highs.first.map { "Today  H: \(Int($0.rounded()))°  L: \(Int((lows.first ?? 0).rounded()))°" } ?? "",
                                  humidity.map { "Humidity  \($0)%" } ?? ""].filter { !$0.isEmpty })
    }

    static func stock(symbol: String) async throws -> WidgetFeed {
        let safe = symbol.uppercased().filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        guard !safe.isEmpty else { throw WidgetFeedError.noResults }
        let url = URL(string: "https://api.nasdaq.com/api/quote/\(safe)/chart?assetclass=stocks")!
        let result = try await json(url, browserHeader: true)
        guard let data = result["data"] as? [String: Any],
              let price = data["lastSalePrice"] as? String else { throw WidgetFeedError.noResults }
        let change = data["percentageChange"] as? String ?? ""
        let asOf = data["timeAsOf"] as? String ?? "Latest available"
        let samples = (data["chart"] as? [[String: Any]] ?? []).compactMap { $0["y"] as? Double }
        let strideSize = max(1, samples.count / 80)
        let reduced = Swift.stride(from: 0, to: samples.count, by: strideSize).map { samples[$0] }
        return WidgetFeed(subtitle: "\(safe) · \(asOf)",
                          lines: ["\(price)  \(change)", "Quote from Nasdaq · may be delayed"], chart: reduced)
    }

    private static func json(_ url: URL, browserHeader: Bool = false) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if browserHeader { request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw WidgetFeedError.badResponse }
        return root
    }
}
