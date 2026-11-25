import Foundation

/// A phase: a state name, shared by every project that has a state of that name.
public struct Phase: Identifiable, Hashable, Sendable {
    public var name: String
    /// The lowest sequence any project gives it, for ordering.
    public var sequence: Double
    public var group: String
    public var color: String?
    public var id: String { name }

    public init(name: String, sequence: Double, group: String, color: String? = nil) {
        self.name = name
        self.sequence = sequence
        self.group = group
        self.color = color
    }
}

/// One project's items within a phase.
public struct ProjectSection: Identifiable, Hashable, Sendable {
    public var project: WorkItem.ProjectRef
    public var items: [WorkItem]
    public var id: String { project.id }
}

/// A card in the menu: one phase, its items grouped by project.
public struct PhaseSection: Identifiable, Hashable, Sendable {
    public var phase: Phase
    public var projects: [ProjectSection]
    public var id: String { phase.name }
    public var count: Int { projects.reduce(0) { $0 + $1.items.count } }
    public var items: [WorkItem] { projects.flatMap(\.items) }
}

public enum Workflow {
    /// The state an item moves to when approved: the next by sequence in its project, never a
    /// cancelled or triage state. Nil when the item is in the last state, or its state is unknown.
    public static func nextState(after stateID: String, in states: [PlaneState]) -> PlaneState? {
        guard let current = states.first(where: { $0.id == stateID }) else { return nil }
        return states
            .filter { $0.sequence > current.sequence && !$0.isCancelled && $0.isTriage != true }
            .min { $0.sequence < $1.sequence }
    }

    /// Every state name across the projects, once each, in sequence order. Triage states
    /// are left out.
    public static func phases(_ statesByProject: [[PlaneState]]) -> [Phase] {
        var byName: [String: Phase] = [:]
        for state in statesByProject.joined() where state.isTriage != true {
            if let known = byName[state.name], known.sequence <= state.sequence { continue }
            byName[state.name] = Phase(name: state.name, sequence: state.sequence, group: state.group, color: state.color)
        }
        return byName.values.sorted {
            $0.sequence != $1.sequence ? $0.sequence < $1.sequence
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// A PQL filter for items in any of the phases, in any of the projects. Projects must be
    /// given by UUID; Plane rejects identifiers here.
    public static func pql(phases: [String], projectIDs: [String]) -> String {
        "state IN (\(phases.map(quote).joined(separator: ", "))) AND project IN (\(projectIDs.map(quote).joined(separator: ", ")))"
    }

    /// A PQL string literal.
    public static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Percent-encodes a query value, leaving only unreserved characters; `+`, `&` and `=`
    /// are encoded too.
    public static func encodeQueryValue(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // `alphanumerics` includes non-ASCII letters; encode those as well.
        return text.unicodeScalars.map { scalar in
            scalar.isASCII && allowed.contains(scalar) ? String(scalar)
                : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }

    /// The item's page on the web.
    public static func browseURL(workspace: String, key: String) -> URL? {
        URL(string: "https://app.plane.so/\(encodeQueryValue(workspace))/browse/\(encodeQueryValue(key))/")
    }

    /// Cards in phase order, leaving out empty phases. Inside a card, projects follow
    /// `projectOrder` (ids), and each project's items are most recently updated first.
    public static func sections(_ items: [WorkItem], phases: [Phase], projectOrder: [String]) -> [PhaseSection] {
        let rank = Dictionary(projectOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return phases.compactMap { phase in
            let members = items.filter { $0.state.name == phase.name }
            guard !members.isEmpty else { return nil }
            let projects = Dictionary(grouping: members, by: \.project.id)
                .map { _, list in
                    ProjectSection(project: list[0].project, items: list.sorted {
                        let (x, y) = ($0.updatedAt ?? .distantPast, $1.updatedAt ?? .distantPast)
                        return x != y ? x > y : $0.sequenceID > $1.sequenceID
                    })
                }
                .sorted {
                    let (x, y) = (rank[$0.project.id] ?? .max, rank[$1.project.id] ?? .max)
                    return x != y ? x < y : $0.project.identifier < $1.project.identifier
                }
            return PhaseSection(phase: phase, projects: projects)
        }
    }

    /// Items that are in a phase now and were not in it before: new ones, and ones that moved in.
    public static func arrivals(old: [WorkItem], new: [WorkItem]) -> [WorkItem] {
        let before = Set(old.map { "\($0.id)|\($0.state.name)" })
        return new.filter { !before.contains("\($0.id)|\($0.state.name)") }
    }
}
