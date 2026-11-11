import Foundation
struct GradientCatalog: Decodable { let profileByPetID: [String: PetGradientProfile] }
struct PetGradientProfile: Decodable {
    let displayName: String?
    let palette: PetPalette
    let gradients: PetGradients
    init(palette: PetPalette, gradients: PetGradients) {
        displayName = nil
        self.palette = palette
        self.gradients = gradients
    }
}
struct PetPalette: Decodable { let shadow, primary, secondary, accent, highlight, foreground: String }
struct PetGradients: Decodable { let ambient, thinking, working, success, warning, error: GradientRecipe }
struct GradientRecipe: Decodable { let angleDegrees: Double, cycleDurationMs: Int, stops: [GradientStop] }
struct GradientStop: Decodable { let location: Double, color: String }

enum Catalog {
    private static let catalog: GradientCatalog? = {
        guard let url = URL(string: "file:///Users/vishayagarwal/Documents/Codex/2026-09-29/can-y/webby-unified/gradient_profiles.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GradientCatalog.self, from: data)
    }()

    static let presets: [(id: String, name: String)] = {
        (catalog?.profileByPetID ?? [:]).map { id, profile in
            (id: id, name: profile.displayName ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

}
_ = Catalog.presets
let began = ProcessInfo.processInfo.systemUptime
var count = 0
for _ in 0..<10000 { count += Catalog.presets.count }
print("\(count) presets in \((ProcessInfo.processInfo.systemUptime-began)*1000) ms")
