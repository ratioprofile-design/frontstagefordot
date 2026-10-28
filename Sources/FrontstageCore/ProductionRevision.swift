import Foundation

public enum RevisionColor: String, CaseIterable, Codable, Sendable {
    case white = "White"
    case blue = "Blue"
    case pink = "Pink"
    case yellow = "Yellow"
    case green = "Green"
    case goldenrod = "Goldenrod"
    case buff = "Buff"
    case salmon = "Salmon"
    case cherry = "Cherry"
    case secondWhite = "2nd White"

    public var hexColor: String {
        switch self {
        case .white: return "#FFFFFF"
        case .blue: return "#4A90E2"
        case .pink: return "#E25A98"
        case .yellow: return "#F5A623"
        case .green: return "#7ED321"
        case .goldenrod: return "#D08B2A"
        case .buff: return "#E8D8A6"
        case .salmon: return "#FA8072"
        case .cherry: return "#DE3163"
        case .secondWhite: return "#F0F0F0"
        }
    }

    public var label: String {
        switch self {
        case .white: return "Production Draft (White)"
        default: return "\(rawValue) Revision"
        }
    }

    public var next: RevisionColor? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }
}

#if canImport(SwiftUI)
import SwiftUI

extension RevisionColor {
    public var swiftUIColor: Color {
        switch self {
        case .white: return Color.white
        case .blue: return Color(red: 0.29, green: 0.56, blue: 0.89)
        case .pink: return Color(red: 0.89, green: 0.35, blue: 0.60)
        case .yellow: return Color(red: 0.96, green: 0.65, blue: 0.14)
        case .green: return Color(red: 0.49, green: 0.83, blue: 0.13)
        case .goldenrod: return Color(red: 0.82, green: 0.55, blue: 0.16)
        case .buff: return Color(red: 0.91, green: 0.85, blue: 0.65)
        case .salmon: return Color(red: 0.98, green: 0.50, blue: 0.45)
        case .cherry: return Color(red: 0.87, green: 0.19, blue: 0.39)
        case .secondWhite: return Color(red: 0.94, green: 0.94, blue: 0.94)
        }
    }
}
#endif


public struct ProductionRevision: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var color: RevisionColor
    public var date: Date
    public var label: String
    public var isLocked: Bool
    public var sceneBaselineHTML: [String: String]

    public init(id: String = UUID().uuidString,
                color: RevisionColor = .white,
                date: Date = Date(),
                label: String = "Production Draft",
                isLocked: Bool = false,
                sceneBaselineHTML: [String: String] = [:]) {
        self.id = id
        self.color = color
        self.date = date
        self.label = label
        self.isLocked = isLocked
        self.sceneBaselineHTML = sceneBaselineHTML
    }

    public var headerString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yy"
        return "(\(label.uppercased()) - \(formatter.string(from: date)))"
    }
}

extension Project {
    public var currentRevision: ProductionRevision? {
        get {
            guard let obj = state["productionRevision"]?.object else { return nil }
            guard let colorStr = obj["color"]?.string, let color = RevisionColor(rawValue: colorStr) else { return nil }
            let id = obj["id"]?.string ?? UUID().uuidString
            let label = obj["label"]?.string ?? color.label
            let isLocked = obj["isLocked"]?.boolean ?? false
            let timestamp: Double
            if case .number(let n) = obj["date"] {
                timestamp = NSDecimalNumber(decimal: n).doubleValue / 1000.0
            } else {
                timestamp = Date().timeIntervalSince1970
            }
            let baselines = (obj["sceneBaselineHTML"]?.object ?? [:]).compactMapValues(\.string)
            return ProductionRevision(id: id, color: color, date: Date(timeIntervalSince1970: timestamp),
                                      label: label, isLocked: isLocked, sceneBaselineHTML: baselines)
        }
        set {
            if let rev = newValue {
                var baselines: [String: JSONValue] = [:]
                for (k, v) in rev.sceneBaselineHTML { baselines[k] = .string(v) }
                state["productionRevision"] = .object([
                    "id": .string(rev.id),
                    "color": .string(rev.color.rawValue),
                    "label": .string(rev.label),
                    "isLocked": .bool(rev.isLocked),
                    "date": .number(Decimal(rev.date.timeIntervalSince1970 * 1000.0)),
                    "sceneBaselineHTML": .object(baselines)
                ])
            } else {
                state["productionRevision"] = .null
            }
        }
    }

    public mutating func startNextRevision(label customLabel: String? = nil) {
        let nextColor = currentRevision?.color.next ?? .blue
        let label = customLabel ?? nextColor.label
        var baselines: [String: String] = [:]
        for scene in scenes {
            baselines[String(describing: scene.id)] = scene.html
        }
        currentRevision = ProductionRevision(color: nextColor, date: Date(), label: label, isLocked: true, sceneBaselineHTML: baselines)
    }

    public mutating func toggleProductionLock() {
        if var rev = currentRevision {
            rev.isLocked.toggle()
            currentRevision = rev
        } else {
            var baselines: [String: String] = [:]
            for scene in scenes { baselines[String(describing: scene.id)] = scene.html }
            currentRevision = ProductionRevision(color: .white, date: Date(), label: "Production Draft", isLocked: true, sceneBaselineHTML: baselines)
        }
    }

    public mutating func setRevisionColor(_ color: RevisionColor, label customLabel: String? = nil) {
        var baselines = currentRevision?.sceneBaselineHTML ?? [:]
        if baselines.isEmpty {
            for scene in scenes { baselines[String(describing: scene.id)] = scene.html }
        }
        let label = customLabel ?? (currentRevision?.label ?? color.label)
        currentRevision = ProductionRevision(color: color, date: Date(), label: label, isLocked: currentRevision?.isLocked ?? true, sceneBaselineHTML: baselines)
    }

    public mutating func updateRevisionLabel(_ newLabel: String) {
        guard var rev = currentRevision else { return }
        rev.label = newLabel
        currentRevision = rev
    }

    public mutating func clearProductionRevision() {
        currentRevision = nil
    }
}

