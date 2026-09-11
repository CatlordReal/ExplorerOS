import Foundation

public enum GlassGesture: String, CaseIterable, Sendable {
    case tap, doubleTap, swipeLeft, swipeRight, swipeDown, camera, cameraLongPress
}
public enum CompanionAction: Equatable {
    case nextStep, previousStep, dismiss, showCompanion, none
}
public enum GlassControls {
    public static func action(for gesture: GlassGesture, routeActive: Bool) -> CompanionAction {
        switch gesture {
        case .swipeRight: return routeActive ? .nextStep : .none
        case .swipeLeft: return routeActive ? .previousStep : .none
        case .swipeDown: return .dismiss
        case .camera, .cameraLongPress: return .showCompanion
        case .tap, .doubleTap: return .none
        }
    }
}

public struct RouteStep: Equatable, Sendable {
    public let instruction: String
    public let distance: Double
    public init(instruction: String, distance: Double) { self.instruction = instruction; self.distance = distance }
}
public struct RouteProgress: Equatable, Sendable {
    public private(set) var steps: [RouteStep]
    public private(set) var index = 0
    public let destination: String
    public init(steps: [RouteStep], destination: String) { self.steps = steps.filter { !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }; self.destination = destination }
    public var current: RouteStep? { steps.indices.contains(index) ? steps[index] : nil }
    public mutating func move(_ delta: Int) { index = max(0, min(max(0, steps.count - 1), index + delta)) }
    public func message(source: String = "mapkit") -> LinkMessage? {
        guard let current else { return nil }
        let distance = current.distance < 1000 ? "\(Int(current.distance.rounded())) m" : String(format: "%.1f km", current.distance / 1000)
        return LinkMessage(type: "navigation", payload: ["instruction": current.instruction, "distance": distance, "destination": destination, "step": "\(index + 1)", "total": "\(steps.count)", "source": source])
    }
}
