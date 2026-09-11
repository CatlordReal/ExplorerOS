import Foundation

public enum SolarPhase: String, CaseIterable { case night, dawn, day, goldenHour, sunset, dusk }
public struct SolarTimes: Equatable {
    public let sunrise: Date
    public let sunset: Date
    public let estimated: Bool
    public init(sunrise: Date, sunset: Date, estimated: Bool) { self.sunrise = sunrise; self.sunset = sunset; self.estimated = estimated }
    public func phase(at date: Date) -> SolarPhase {
        guard sunrise < sunset else { return .night }
        if date < sunrise.addingTimeInterval(-1800) { return .night }
        if date < sunrise.addingTimeInterval(1800) { return .dawn }
        if date < sunset.addingTimeInterval(-3600) { return .day }
        if date < sunset { return .goldenHour }
        if date < sunset.addingTimeInterval(1800) { return .sunset }
        if date < sunset.addingTimeInterval(5400) { return .dusk }
        return .night
    }
}
public enum SolarCalculator {
    /// NOAA-style solar approximation, sufficient for appearance scheduling, never navigation.
    public static func times(date: Date, latitude: Double?, longitude: Double?, sunriseHour: Int = 7, sunsetHour: Int = 19, calendar: Calendar = .current) -> SolarTimes {
        let start = calendar.startOfDay(for: date)
        let fallback = SolarTimes(sunrise: calendar.date(byAdding: .hour, value: sunriseHour, to: start)!, sunset: calendar.date(byAdding: .hour, value: sunsetHour, to: start)!, estimated: true)
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return fallback }
        func event(rising: Bool) -> Date? {
            func norm(_ x: Double, _ range: Double) -> Double { let r = x.truncatingRemainder(dividingBy: range); return r < 0 ? r + range : r }
            func sinD(_ x: Double) -> Double { sin(x * .pi / 180) }
            func cosD(_ x: Double) -> Double { cos(x * .pi / 180) }
            let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
            let longitudeHour = longitude / 15
            let t = day + ((rising ? 6 : 18) - longitudeHour) / 24
            let anomaly = 0.9856 * t - 3.289
            let l = norm(anomaly + 1.916 * sinD(anomaly) + 0.020 * sinD(2 * anomaly) + 282.634, 360)
            var ra = norm(atan(0.91764 * tan(l * .pi / 180)) * 180 / .pi, 360)
            ra += floor(l / 90) * 90 - floor(ra / 90) * 90
            ra /= 15
            let sd = 0.39782 * sinD(l)
            let cosH = (cosD(90.833) - sd * sinD(latitude)) / (cos(asin(sd)) * cosD(latitude))
            guard cosH.isFinite, (-1...1).contains(cosH) else { return nil }
            let rawH = acos(cosH) * 180 / .pi
            let h = (rising ? 360 - rawH : rawH) / 15
            let hour = norm(h + ra - 0.06571 * t - 6.622 - longitudeHour, 24)
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
            var parts = calendar.dateComponents([.year, .month, .day], from: date); parts.timeZone = utc.timeZone
            guard let midnight = utc.date(from: parts) else { return nil }
            var result = midnight.addingTimeInterval(hour * 3600)
            if calendar.startOfDay(for: result) < start { result = result.addingTimeInterval(86400) }
            if calendar.startOfDay(for: result) > start { result = result.addingTimeInterval(-86400) }
            return result
        }
        guard let rise = event(rising: true), let set = event(rising: false), rise < set else { return fallback }
        return SolarTimes(sunrise: rise, sunset: set, estimated: false)
    }
}
