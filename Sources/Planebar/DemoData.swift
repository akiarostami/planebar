import Foundation
import PlanebarCore

/// Invented projects and items, shown when the app is launched with PLANEBAR_DEMO set.
/// Demo mode does not talk to Plane, does not read the Keychain and saves nothing.
enum DemoData {
    static let isOn = ProcessInfo.processInfo.environment["PLANEBAR_DEMO"] != nil

    static let projects = [
        PlaneProject(id: "p-shop", identifier: "SHOP", name: "Storefront"),
        PlaneProject(id: "p-blog", identifier: "BLOG", name: "Blog"),
        PlaneProject(id: "p-app", identifier: "APP", name: "Mobile"),
        PlaneProject(id: "p-bill", identifier: "BILL", name: "Billing"),
        PlaneProject(id: "p-docs", identifier: "DOCS", name: "Docs"),
    ]

    /// Plane's default states, the same in every project.
    static func states(project: String) -> [PlaneState] {
        [
            PlaneState(id: "\(project)-backlog", name: "Backlog", group: "backlog", sequence: 15000, color: "#60646C"),
            PlaneState(id: "\(project)-todo", name: "Todo", group: "unstarted", sequence: 25000, color: "#60646C"),
            PlaneState(id: "\(project)-progress", name: "In Progress", group: "started", sequence: 35000, color: "#F59E0B"),
            PlaneState(id: "\(project)-review", name: "Review", group: "started", sequence: 40000, color: "#8B5CF6"),
            PlaneState(id: "\(project)-done", name: "Done", group: "completed", sequence: 45000, color: "#46A758"),
            PlaneState(id: "\(project)-cancelled", name: "Cancelled", group: "cancelled", sequence: 55000, color: "#9AA4BC"),
        ]
    }

    static func labels(project: String) -> [PlaneLabel] {
        [
            PlaneLabel(id: "\(project)-bug", name: "Bug", color: "#EF4444"),
            PlaneLabel(id: "\(project)-feature", name: "Feature", color: "#3B82F6"),
            PlaneLabel(id: "\(project)-ui", name: "UI", color: "#A855F7"),
        ]
    }

    static func items(now: Date = Date()) -> [WorkItem] {
        func item(_ project: String, _ number: Int, _ name: String, _ phase: String, minutes: Double,
                  priority: String = "none", labels: [String] = [], module: String? = nil, text: String = "") -> WorkItem {
            let owner = projects.first { $0.identifier == project }!
            let state = states(project: owner.id).first { $0.name == phase }!
            return WorkItem(id: "\(project)-\(number)", name: name, sequenceID: number, priority: priority,
                            labels: labels.map { "\(owner.id)-\($0)" }, description: text, moduleName: module,
                            updatedAt: now.addingTimeInterval(-minutes * 60),
                            project: .init(id: owner.id, identifier: owner.identifier, name: owner.name),
                            state: .init(state))
        }
        return [
            item("SHOP", 139, "Round tax per line on partial refunds", "Review", minutes: 4, priority: "high",
                 labels: ["bug"], module: "Checkout",
                 text: "Partial refunds round the tax on the total, so a refund of two items out of three can be a cent off the original charge. Round per line, as the invoice does, and keep the remainder on the last line.\n\nDone: refunds now match the invoice for every order in last month's export. Check one refund in the staging dashboard before closing."),
            item("SHOP", 142, "Saved cards at checkout", "Review", minutes: 52, priority: "medium", labels: ["feature"],
                 module: "Checkout", text: "Offer the customer's saved cards first, with the most recent one selected."),
            item("BLOG", 57, "RSS feed lists drafts", "Review", minutes: 180, priority: "urgent", labels: ["bug"],
                 text: "Drafts with a publish date in the future appear in the feed."),
            item("APP", 88, "Dark mode for the settings screen", "Review", minutes: 1500, priority: "low", labels: ["ui"]),
            item("SHOP", 145, "Gift cards", "In Progress", minutes: 25, priority: "medium", labels: ["feature"], module: "Checkout"),
            item("BILL", 23, "Prorate when switching plans mid-cycle", "In Progress", minutes: 300, priority: "high",
                 text: "Credit the unused part of the old plan on the next invoice."),
            item("BILL", 24, "Invoice PDF footer", "Todo", minutes: 900),
        ]
    }
}

/// Plane, as demo mode sees it: the invented data, kept in memory. Moves take a moment,
/// like the real thing.
actor DemoPlane: PlaneService {
    private var items = DemoData.items()

    func projects() async throws -> [PlaneProject] { DemoData.projects }

    func states(project: String) async throws -> [PlaneState] { DemoData.states(project: project) }

    func labels(project: String) async throws -> [PlaneLabel] { DemoData.labels(project: project) }

    func workItems(phases: [String], projectIDs: [String]) async throws -> [WorkItem] {
        items.filter { phases.contains($0.state.name) && projectIDs.contains($0.project.id) }
    }

    func setState(project: String, item: String, state: String) async throws {
        try await Task.sleep(for: .milliseconds(400))
        guard let index = items.firstIndex(where: { $0.id == item }),
              let target = DemoData.states(project: project).first(where: { $0.id == state }) else {
            throw PlaneError.notFound
        }
        items[index].state = .init(target)
        items[index].updatedAt = Date()
    }
}
