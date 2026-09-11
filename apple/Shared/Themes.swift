import SwiftUI
import ExplorerLinkCore

struct LinkPalette: Identifiable {
    let id: String
    let name: String
    let dark: Bool
    let background: UInt32
    let surface: UInt32
    let text: UInt32
    let secondary: UInt32
    let accent: UInt32
    var bg: Color { Color(hex: background) }
    var panel: Color { Color(hex: surface) }
    var fg: Color { Color(hex: text) }
    var muted: Color { Color(hex: secondary) }
    var tint: Color { Color(hex: accent) }
    func matching(_ scheme: ColorScheme) -> Self {
        let wantsDark = scheme == .dark
        guard dark != wantsDark else { return self }
        let catppuccin = ["latte", "frappe", "macchiato", "mocha"].contains(id)
        return .named(catppuccin ? (wantsDark ? "mocha" : "latte") : (wantsDark ? "dusk" : "dawnPaper"))
    }
    static let all: [Self] = [
        .init(id: "latte", name: "Latte", dark: false, background: 0xEFF1F5, surface: 0xE6E9EF, text: 0x4C4F69, secondary: 0x626780, accent: 0x8839EF),
        .init(id: "frappe", name: "Frappé", dark: true, background: 0x303446, surface: 0x414559, text: 0xC6D0F5, secondary: 0xB5BFDF, accent: 0xCA9EE6),
        .init(id: "macchiato", name: "Macchiato", dark: true, background: 0x24273A, surface: 0x363A4F, text: 0xCAD3F5, secondary: 0xB8C0E0, accent: 0xC6A0F6),
        .init(id: "mocha", name: "Mocha", dark: true, background: 0x1E1E2E, surface: 0x313244, text: 0xCDD6F4, secondary: 0xBAC2DE, accent: 0xCBA6F7),
        .init(id: "sand", name: "Sand", dark: false, background: 0xF4ECD8, surface: 0xE9DCC0, text: 0x3D352A, secondary: 0x665744, accent: 0x815724),
        .init(id: "dawnPaper", name: "Dawn Paper", dark: false, background: 0xFFF6E8, surface: 0xF6E8D2, text: 0x40352F, secondary: 0x6F5C50, accent: 0xA43E28),
        .init(id: "goldenSand", name: "Golden Sand", dark: false, background: 0xEBD7A5, surface: 0xDDC58D, text: 0x382E20, secondary: 0x62503B, accent: 0x855016),
        .init(id: "goldenPaper", name: "Golden Paper", dark: false, background: 0xEAD4A6, surface: 0xDFC493, text: 0x382E27, secondary: 0x635044, accent: 0x8F3527),
        .init(id: "sunset", name: "Sunset", dark: true, background: 0x2A1F2D, surface: 0x443044, text: 0xFFE9D6, secondary: 0xE0C1BD, accent: 0xFFAB88),
        .init(id: "dusk", name: "Dusk", dark: true, background: 0x20233B, surface: 0x303653, text: 0xE7E9FF, secondary: 0xBBC2E6, accent: 0xB8A1FF)
    ]
    static func named(_ id: String) -> Self { all.first { $0.id == id } ?? all[3] }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255) }
}
private struct PaletteKey: EnvironmentKey { static let defaultValue = LinkPalette.named("mocha") }
extension EnvironmentValues { var linkPalette: LinkPalette { get { self[PaletteKey.self] } set { self[PaletteKey.self] = newValue } } }

final class ThemeSettings: ObservableObject {
    @AppStorage("themeSelection") var selected = "mocha" { willSet { objectWillChange.send() } }
    @AppStorage("appearanceChoice") var appearance = "system" { willSet { objectWillChange.send() } }
    @AppStorage("themePolicy") var policy = "manual" { willSet { objectWillChange.send() } }
    @AppStorage("solarLatitude") var latitude = "" { willSet { objectWillChange.send() } }
    @AppStorage("solarLongitude") var longitude = "" { willSet { objectWillChange.send() } }
    @AppStorage("themeSunriseHour") var sunrise = 7 { willSet { objectWillChange.send() } }
    @AppStorage("themeSunsetHour") var sunset = 19 { willSet { objectWillChange.send() } }
    func times(_ date: Date) -> SolarTimes { SolarCalculator.times(date: date, latitude: policy == "time" ? nil : Double(latitude), longitude: policy == "time" ? nil : Double(longitude), sunriseHour: sunrise, sunsetHour: sunset) }
    func palette(_ date: Date) -> LinkPalette {
        if policy == "manual" { return .named(selected) }
        let phase = times(date).phase(at: date)
        if policy == "catppuccin" {
            switch phase { case .dawn, .day: return .named("latte"); case .goldenHour: return .named("frappe"); case .sunset: return .named("macchiato"); case .dusk, .night: return .named("mocha") }
        }
        switch phase { case .dawn: return .named("dawnPaper"); case .day: return .named("sand"); case .goldenHour: return .named("goldenSand"); case .sunset: return .named("sunset"); case .dusk, .night: return .named("dusk") }
    }
    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
}

struct ThemedRoot<Content: View>: View {
    @ObservedObject var settings: ThemeSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemScheme
    @ViewBuilder let content: () -> Content
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { tick in
            let palette = settings.palette(tick.date).matching(settings.colorScheme ?? systemScheme)
            content().environment(\.linkPalette, palette).tint(palette.tint)
                .preferredColorScheme(settings.colorScheme)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: palette.id)
        }
    }
}

struct ThemeSettingsView: View {
    @ObservedObject var settings: ThemeSettings
    var body: some View {
        Section("Appearance") {
            Picker("Native appearance", selection: $settings.appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
            Picker("Theme switching", selection: $settings.policy) { Text("Manual override").tag("manual"); Text("Solar").tag("solar"); Text("Catppuccin by sun").tag("catppuccin"); Text("By time").tag("time") }
            Picker("Theme", selection: $settings.selected) { ForEach(LinkPalette.all) { Text($0.name).tag($0.id) } }
                .disabled(settings.policy != "manual")
            if settings.policy != "manual" {
                if settings.policy != "time" {
                    TextField("Latitude (optional)", text: $settings.latitude)
                    TextField("Longitude (optional)", text: $settings.longitude)
                }
                Stepper("Sunrise fallback: \(settings.sunrise):00", value: $settings.sunrise, in: 0...11)
                Stepper("Sunset fallback: \(settings.sunset):00", value: $settings.sunset, in: 12...23)
                Text(settings.times(.now).estimated ? "Using local clock times. Add coordinates for sunrise, golden hour, sunset, and dusk. Polar days use these fallback times." : "Solar times calculated locally. Coordinates stay on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
