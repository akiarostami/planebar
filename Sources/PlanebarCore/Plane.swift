import Foundation

/// A Plane project, as `GET /projects/` lists it.
public struct PlaneProject: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    /// The short key in front of item numbers, such as "CAS".
    public var identifier: String
    public var name: String

    public init(id: String, identifier: String, name: String) {
        self.id = id
        self.identifier = identifier
        self.name = name
    }
}

/// One of a project's states, which Planebar calls phases.
public struct PlaneState: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// backlog, unstarted, started, completed or cancelled.
    public var group: String
    /// The state's place in the project's order; Plane uses floats such as 35000.0.
    public var sequence: Double
    /// A hex colour such as "#8B5CF6".
    public var color: String?
    /// Intake's triage state, which is not part of the project's own order.
    public var isTriage: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, group, sequence, color
        case isTriage = "is_triage"
    }

    public init(id: String, name: String, group: String, sequence: Double, color: String? = nil, isTriage: Bool? = nil) {
        self.id = id
        self.name = name
        self.group = group
        self.sequence = sequence
        self.color = color
        self.isTriage = isTriage
    }

    public var isCancelled: Bool { group == "cancelled" }
}

public struct PlaneLabel: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var color: String?

    public init(id: String, name: String, color: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// A work item, decoded from `/work-items/?expand=state,project`. Without the expansion
/// `project` and `state` are bare ids; then only their ids are filled in.
public struct WorkItem: Identifiable, Hashable, Sendable, Decodable {
    public struct ProjectRef: Hashable, Sendable {
        public var id: String
        public var identifier: String
        public var name: String

        public init(id: String, identifier: String, name: String) {
            self.id = id
            self.identifier = identifier
            self.name = name
        }
    }

    public struct StateRef: Hashable, Sendable {
        public var id: String
        public var name: String
        public var group: String
        public var color: String?

        public init(id: String, name: String, group: String, color: String? = nil) {
            self.id = id
            self.name = name
            self.group = group
            self.color = color
        }

        public init(_ state: PlaneState) {
            self.init(id: state.id, name: state.name, group: state.group, color: state.color)
        }
    }

    public var id: String
    public var name: String
    public var sequenceID: Int
    /// urgent, high, medium, low or none.
    public var priority: String
    /// Label ids; their names come from the project's labels.
    public var labels: [String]
    public var description: String
    public var moduleName: String?
    public var updatedAt: Date?
    public var createdAt: Date?
    public var project: ProjectRef
    public var state: StateRef

    public init(id: String, name: String, sequenceID: Int, priority: String = "none", labels: [String] = [],
                description: String = "", moduleName: String? = nil, updatedAt: Date? = nil, createdAt: Date? = nil,
                project: ProjectRef, state: StateRef) {
        self.id = id
        self.name = name
        self.sequenceID = sequenceID
        self.priority = priority
        self.labels = labels
        self.description = description
        self.moduleName = moduleName
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.project = project
        self.state = state
    }

    /// The item's name in Plane, such as "SHOP-57".
    public var key: String { "\(project.identifier)-\(sequenceID)" }

    enum CodingKeys: String, CodingKey {
        case id, name, priority, labels, project, state
        case sequenceID = "sequence_id"
        case description = "description_stripped"
        case moduleName = "min_module_name"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case stateGroup = "state_group"
    }

    private struct ExpandedProject: Decodable {
        var id: String
        var identifier: String?
        var name: String?
    }

    private struct ExpandedState: Decodable {
        var id: String
        var name: String?
        var group: String?
        var color: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        sequenceID = try c.decodeIfPresent(Int.self, forKey: .sequenceID) ?? 0
        priority = try c.decodeIfPresent(String.self, forKey: .priority) ?? "none"
        labels = (try? c.decodeIfPresent([String].self, forKey: .labels)) ?? []
        description = (try c.decodeIfPresent(String.self, forKey: .description) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        moduleName = try c.decodeIfPresent(String.self, forKey: .moduleName)
        updatedAt = (try c.decodeIfPresent(String.self, forKey: .updatedAt)).flatMap(PlaneDate.parse)
        createdAt = (try c.decodeIfPresent(String.self, forKey: .createdAt)).flatMap(PlaneDate.parse)
        if let expanded = try? c.decode(ExpandedProject.self, forKey: .project) {
            project = ProjectRef(id: expanded.id, identifier: expanded.identifier ?? "", name: expanded.name ?? "")
        } else {
            project = ProjectRef(id: try c.decode(String.self, forKey: .project), identifier: "", name: "")
        }
        let group = try c.decodeIfPresent(String.self, forKey: .stateGroup) ?? ""
        if let expanded = try? c.decode(ExpandedState.self, forKey: .state) {
            state = StateRef(id: expanded.id, name: expanded.name ?? "", group: expanded.group ?? group, color: expanded.color)
        } else {
            state = StateRef(id: try c.decode(String.self, forKey: .state), name: "", group: group)
        }
    }
}

/// One page of a list. Plane answers some lists with a bare array and most with
/// `{results, next_page_results, next_cursor}`; both decode.
public struct Page<Element: Decodable>: Decodable {
    public var results: [Element]
    public var hasNext: Bool
    public var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case hasNext = "next_page_results"
        case nextCursor = "next_cursor"
    }

    public init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([Element].self) {
            results = list
            hasNext = false
            nextCursor = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decode([Element].self, forKey: .results)
        hasNext = try c.decodeIfPresent(Bool.self, forKey: .hasNext) ?? false
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

/// Plane's timestamps, such as "2026-11-24T17:12:43.951797-08:00".
public enum PlaneDate {
    public static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // Drop a fraction the formatter will not take, keeping the zone.
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let rest = text[dot...].drop { $0 == "." || $0.isNumber }
        return plain.date(from: String(text[..<dot]) + rest)
    }
}
