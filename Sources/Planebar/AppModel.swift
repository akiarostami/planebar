import AppKit
import Observation
import PlanebarCore
import ServiceManagement
import SwiftUI

enum SettingsPane: Hashable {
    case general, account, projects, phases, about
}

/// A banner: an item has entered a watched phase.
struct Notice: Identifiable, Equatable {
    let id: String
    let item: WorkItem

    init(item: WorkItem) {
        self.item = item
        id = "\(item.id)|\(item.state.name)"
    }
}

/// The last approval, or its undo, shown at the foot of the menu for a few seconds.
struct Move: Identifiable, Equatable {
    let id = UUID()
    /// The item as it was before the move.
    let item: WorkItem
    let from: WorkItem.StateRef
    let to: WorkItem.StateRef
    let isUndo: Bool
    var failure: String?
}

enum ConnectionTest: Equatable {
    case running
    case passed(String)
    case failed(String)
}

/// The app's state: what Plane reports, what is watched, and the settings.
@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case noKey
        case connecting
        case live
        case failed(String)
    }

    var connection = Connection.connecting
    var projects: [PlaneProject] = []
    /// Each project's states, by project id.
    var states: [String: [PlaneState]] = [:]
    /// Each project's labels, by project id, then label id.
    var labels: [String: [String: PlaneLabel]] = [:]
    /// The items Plane last listed in the watched phases.
    var items: [WorkItem] = []
    var lastRefresh: Date?
    var isRefreshing = false
    /// States to show for items moved here before Plane's list catches up, by item id.
    var overrides: [String: WorkItem.StateRef] = [:]
    var move: Move?
    var banners: [Notice] = []
    var settingsPane = SettingsPane.general
    /// The row the keyboard is on, by item id; nil until an arrow key is pressed.
    var selectedRow: String?
    /// The row opened out to show its details, by item id.
    var expandedRow: String?
    var hotKeyRefused = false
    var hasKey = false
    var connectionTest: ConnectionTest?

    var workspace: String {
        didSet { save(workspace, "workspace") }
    }
    /// Project ids to watch; nil for all of them.
    var chosenProjects: [String]? {
        didSet {
            save(chosenProjects, "projects")
            settingsChanged()
        }
    }
    /// Phase names to watch; nil for the default, Review.
    var chosenPhases: [String]? {
        didSet {
            save(chosenPhases, "phases")
            settingsChanged()
        }
    }
    var refreshMinutes: Int {
        didSet {
            save(refreshMinutes, "refreshMinutes")
            scheduleTimer()
        }
    }
    var notifies: Bool {
        didSet { save(notifies, "notifies") }
    }
    /// The menu bar colour while items wait: a name from `LabelColour.presets`, or a hex
    /// colour such as "#FF8800".
    var labelColour: String {
        didSet { save(labelColour, "labelColour") }
    }
    var hotKey: KeyCombo? {
        didSet { save(hotKey.flatMap { try? JSONEncoder().encode($0) }, "hotKey") }
    }

    /// Set by the app delegate.
    @ObservationIgnored var openSettings: (SettingsPane) -> Void = { _ in }
    @ObservationIgnored var requestQuit: () -> Void = {}
    /// Opens the menu with an item's row selected and opened out.
    @ObservationIgnored var showItem: (String) -> Void = { _ in }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var service: PlaneService?
    @ObservationIgnored private var metaLoaded: Date?
    /// The phases and projects of the last reading; only items arriving in these are announced.
    @ObservationIgnored private var lastWatched: (phases: Set<String>, projects: Set<String>)?
    /// When Plane confirmed a move, by item id; the override goes with the next reading after that.
    @ObservationIgnored private var confirmed: [String: Date] = [:]
    /// Items moved from here, which are not announced when they arrive somewhere.
    @ObservationIgnored private var ownMoves: [String: Date] = [:]
    @ObservationIgnored private var retryAt: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var moveTimer: DispatchWorkItem?
    @ObservationIgnored private var bannerTimers: [String: DispatchWorkItem] = [:]

    static let bannerSeconds = 6.0
    static let undoSeconds = 6.0

    init() {
        // Demo mode starts from the app's defaults each time, not from the saved settings.
        if DemoData.isOn, let demo = UserDefaults(suiteName: "com.minorkey.planebar.demo") {
            demo.removePersistentDomain(forName: "com.minorkey.planebar.demo")
            defaults = demo
        } else {
            defaults = .standard
        }
        defaults.register(defaults: ["workspace": DemoData.isOn ? "acme" : "", "refreshMinutes": 2, "notifies": true,
                                     "labelColour": "blue"])
        workspace = defaults.string(forKey: "workspace") ?? ""
        chosenProjects = defaults.stringArray(forKey: "projects")
        chosenPhases = defaults.stringArray(forKey: "phases")
        refreshMinutes = max(1, defaults.integer(forKey: "refreshMinutes"))
        notifies = defaults.bool(forKey: "notifies")
        labelColour = defaults.string(forKey: "labelColour") ?? "blue"
        hotKey = defaults.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }

        if DemoData.isOn {
            chosenPhases = ["In Progress", "Review"]
            service = DemoPlane()
            hasKey = true
        } else {
            loadKey()
        }
        if !hasKey { settingsPane = .account }
        scheduleTimer()
        refresh()
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: Key and workspace

    /// Reads the key for the workspace from the Keychain. PLANEBAR_API_KEY, when set, is used
    /// instead, for development.
    private func loadKey() {
        let key = workspace.isEmpty ? nil
            : ProcessInfo.processInfo.environment["PLANEBAR_API_KEY"] ?? Keychain.read(account: workspace)
        hasKey = key != nil
        service = key.map { PlaneClient(key: $0, workspace: workspace) }
    }

    /// Saves a new key in the Keychain and starts again with it.
    func saveKey(_ key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !workspace.isEmpty, !DemoData.isOn else { return }
        guard Keychain.save(key, account: workspace) else {
            connectionTest = .failed("The Keychain refused the key.")
            return
        }
        hasKey = true
        service = PlaneClient(key: key, workspace: workspace)
        restart()
        testConnection()
    }

    func removeKey() {
        guard !DemoData.isOn else { return }
        Keychain.delete(account: workspace)
        loadKey()
        restart()
    }

    func setWorkspace(_ slug: String) {
        let slug = slug.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !slug.isEmpty, slug != workspace, !DemoData.isOn else { return }
        workspace = slug
        chosenProjects = nil
        loadKey()
        restart()
    }

    /// Forgets everything read from Plane and reads it again.
    private func restart() {
        projects = []
        states = [:]
        labels = [:]
        items = []
        overrides = [:]
        metaLoaded = nil
        lastWatched = nil
        lastRefresh = nil
        retryAt = nil
        connectionTest = nil
        connection = hasKey ? .connecting : .noKey
        refresh()
    }

    func testConnection() {
        guard let service else {
            connectionTest = .failed("No API key.")
            return
        }
        connectionTest = .running
        Task { [weak self] in
            do {
                let list = try await service.projects()
                self?.connectionTest = .passed("Connected · \(list.count) project\(list.count == 1 ? "" : "s")")
                if self?.projects.isEmpty == true { self?.refresh() }
            } catch {
                self?.connectionTest = .failed((error as? PlaneError)?.message ?? error.localizedDescription)
            }
        }
    }

    // MARK: What is watched

    func isChosen(_ project: PlaneProject) -> Bool { chosenProjects?.contains(project.id) ?? true }

    func setChosen(_ project: PlaneProject, _ on: Bool) {
        var ids = projects.filter(isChosen).map(\.id)
        if on { ids.append(project.id) } else { ids.removeAll { $0 == project.id } }
        let all = Set(projects.map(\.id))
        chosenProjects = Set(ids) == all ? nil : projects.map(\.id).filter(Set(ids).contains)
    }

    /// The chosen projects' ids, in Plane's order.
    var watchedProjectIDs: [String] {
        projects.isEmpty ? (chosenProjects ?? []) : projects.filter(isChosen).map(\.id)
    }

    /// Every phase of the chosen projects, in sequence order.
    var availablePhases: [Phase] {
        Workflow.phases(watchedProjectIDs.compactMap { states[$0] })
    }

    var watchedPhaseNames: [String] {
        if let chosenPhases { return chosenPhases }
        return availablePhases.contains { $0.name == "Review" } || availablePhases.isEmpty ? ["Review"] : []
    }

    var watchedPhases: [Phase] {
        let names = Set(watchedPhaseNames)
        let known = availablePhases.filter { names.contains($0.name) }
        // A chosen phase whose states are not loaded yet still gets a card.
        let missing = watchedPhaseNames.filter { name in !known.contains { $0.name == name } }
            .map { Phase(name: $0, sequence: .greatestFiniteMagnitude, group: "started") }
        return known + missing
    }

    func isWatched(_ phase: String) -> Bool { watchedPhaseNames.contains(phase) }

    func setWatched(_ phase: String, _ on: Bool) {
        var names = watchedPhaseNames
        if on, !names.contains(phase) { names.append(phase) }
        if !on { names.removeAll { $0 == phase } }
        chosenPhases = names
    }

    private func settingsChanged() {
        if refreshTask != nil {
            refreshAgain = true
        } else if service != nil {
            refresh()
        }
    }

    // MARK: What the menu shows

    /// The items as the menu shows them: moved ones in their new phase, and only those in
    /// a watched phase and project.
    var shownItems: [WorkItem] {
        let phases = Set(watchedPhaseNames)
        let projectIDs = Set(watchedProjectIDs)
        return items.map(shown).filter { phases.contains($0.state.name) && projectIDs.contains($0.project.id) }
    }

    private func shown(_ item: WorkItem) -> WorkItem {
        guard let state = overrides[item.id] else { return item }
        var item = item
        item.state = state
        return item
    }

    var sections: [PhaseSection] {
        Workflow.sections(shownItems, phases: watchedPhases, projectOrder: projects.map(\.id))
    }

    var count: Int { shownItems.count }

    func item(_ id: String?) -> WorkItem? {
        guard let id else { return nil }
        return shownItems.first { $0.id == id }
    }

    func nextState(for item: WorkItem) -> PlaneState? {
        Workflow.nextState(after: item.state.id, in: states[item.project.id] ?? [])
    }

    func labelNames(_ item: WorkItem) -> [PlaneLabel] {
        let known = labels[item.project.id] ?? [:]
        return item.labels.compactMap { known[$0] }
    }

    func url(for item: WorkItem) -> URL? {
        Workflow.browseURL(workspace: workspace, key: item.key)
    }

    func openInPlane(_ item: WorkItem) {
        if let url = url(for: item) { NSWorkspace.shared.open(url) }
    }

    // MARK: Refreshing

    /// A fresh reading, unless one is running or Plane asked us to wait.
    func refresh() {
        guard let service else {
            connection = .noKey
            return
        }
        guard refreshTask == nil else { return }
        if let retryAt, Date() < retryAt { return }
        let started = Date()
        isRefreshing = true
        refreshTask = Task { [weak self] in
            await self?.read(from: service, started: started)
            guard let self else { return }
            self.refreshTask = nil
            self.isRefreshing = false
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    /// Called as the menu opens: a reading if the last is more than 20 seconds old.
    func menuWillOpen() {
        if lastRefresh.map({ Date().timeIntervalSince($0) > 20 }) ?? true { refresh() }
    }

    private var needsMeta: Bool {
        guard let metaLoaded, Date().timeIntervalSince(metaLoaded) < 30 * 60 else { return true }
        return watchedProjectIDs.contains { states[$0] == nil }
    }

    private func read(from service: PlaneService, started: Date) async {
        do {
            if needsMeta { try await loadMeta(from: service) }
            let phases = watchedPhaseNames
            let projectIDs = watchedProjectIDs
            let fresh = try await service.workItems(phases: phases, projectIDs: projectIDs)
            apply(fresh, started: started, watched: (Set(phases), Set(projectIDs)))
            connection = .live
            lastRefresh = Date()
            retryAt = nil
        } catch let error as PlaneError {
            if case .rateLimited(let after) = error {
                let wait = max(after ?? 60, 10)
                retryAt = Date().addingTimeInterval(wait)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait + 1) { [weak self] in self?.refresh() }
            }
            connection = .failed(error.message)
        } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    /// Projects, and the states and labels of the watched ones. These change rarely, so
    /// they are read every half hour, or when the choice of projects changes.
    private func loadMeta(from service: PlaneService) async throws {
        projects = try await service.projects()
        let stale = metaLoaded.map { Date().timeIntervalSince($0) >= 30 * 60 } ?? true
        let ids = watchedProjectIDs.filter { stale || states[$0] == nil }
        // All projects at once: a handful of requests, well inside Plane's limit.
        try await withThrowingTaskGroup(of: (String, [PlaneState], [PlaneLabel]?).self) { group in
            for id in ids {
                group.addTask {
                    async let list = service.states(project: id)
                    // Labels only name things; a failure here does not stop the reading.
                    async let names = try? service.labels(project: id)
                    return (id, try await list, await names)
                }
            }
            for try await (id, list, names) in group {
                states[id] = list
                if let names {
                    labels[id] = Dictionary(names.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                }
            }
        }
        metaLoaded = Date()
    }

    private func apply(_ fresh: [WorkItem], started: Date, watched: (phases: Set<String>, projects: Set<String>)) {
        let fresh = fresh.map(filled)
        for (id, when) in confirmed where when <= started {
            overrides[id] = nil
            confirmed[id] = nil
        }
        let before = shownItems
        items = fresh
        let after = shownItems

        ownMoves = ownMoves.filter { Date().timeIntervalSince($0.value) < 10 * 60 }
        if let last = lastWatched, notifies {
            let arrivals = Workflow.arrivals(old: before, new: after).filter {
                last.phases.contains($0.state.name) && last.projects.contains($0.project.id) && ownMoves[$0.id] == nil
            }
            for item in arrivals.prefix(4) { show(Notice(item: item)) }
        }
        lastWatched = watched

        let ids = Set(after.map(\.id))
        if let row = selectedRow, !ids.contains(row) { selectedRow = nil }
        if let row = expandedRow, !ids.contains(row) { expandedRow = nil }
    }

    /// Fills in the project and state of an item Plane sent without them expanded.
    private func filled(_ item: WorkItem) -> WorkItem {
        var item = item
        if item.project.identifier.isEmpty, let project = projects.first(where: { $0.id == item.project.id }) {
            item.project = .init(id: project.id, identifier: project.identifier, name: project.name)
        }
        if item.state.name.isEmpty, let state = states[item.project.id]?.first(where: { $0.id == item.state.id }) {
            item.state = .init(state)
        }
        return item
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshMinutes * 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Approving

    /// Moves the item to the next state in its project's order. The row goes at once; if
    /// Plane refuses, it comes back and the reason is shown.
    func approve(_ item: WorkItem) {
        let current = shown(item)
        guard let next = nextState(for: current) else {
            NSSound.beep()
            return
        }
        perform(Move(item: current, from: current.state, to: .init(next), isUndo: false))
    }

    /// Puts the last approved item back where it was. Returns false when there is nothing to undo.
    @discardableResult
    func undoMove() -> Bool {
        guard let move, !move.isUndo, move.failure == nil else { return false }
        if !items.contains(where: { $0.id == move.item.id }) { items.append(move.item) }
        var moved = move.item
        moved.state = move.to
        perform(Move(item: moved, from: move.to, to: move.from, isUndo: true))
        selectedRow = selectedRow == nil ? nil : move.item.id
        return true
    }

    private func perform(_ step: Move) {
        guard let service else { return }
        let id = step.item.id
        // Keep the keyboard on a sensible row: the one after, else the one before.
        if !step.isUndo, selectedRow == id {
            let rows = navigableRows
            if let index = rows.firstIndex(of: id) {
                selectedRow = index + 1 < rows.count ? rows[index + 1] : (index > 0 ? rows[index - 1] : nil)
            }
        }
        if expandedRow == id, !step.isUndo { expandedRow = nil }
        withAnimation(.easeOut(duration: 0.15)) { overrides[id] = step.to }
        confirmed[id] = nil
        ownMoves[id] = Date()
        show(step)
        Task { [weak self] in
            do {
                try await service.setState(project: step.item.project.id, item: id, state: step.to.id)
                self?.confirmed[id] = Date()
            } catch {
                guard let self else { return }
                // Back where Plane has it; the next reading confirms.
                withAnimation(.easeOut(duration: 0.15)) { self.overrides[id] = step.from }
                self.confirmed[id] = Date()
                var failed = step
                let reason = (error as? PlaneError)?.message ?? error.localizedDescription
                failed.failure = "\(step.item.key) not moved. \(reason)"
                self.show(failed)
            }
        }
    }

    private func show(_ step: Move) {
        withAnimation(.easeOut(duration: 0.15)) { move = step }
        moveTimer?.cancel()
        let id = step.id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.move?.id == id else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.move = nil }
        }
        moveTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoSeconds + (step.failure == nil ? 0 : 4), execute: work)
    }

    func clearMove() {
        withAnimation(.easeOut(duration: 0.2)) { move = nil }
    }

    // MARK: Keyboard

    enum NavigationKey {
        case up, down, left, right, activate, open, approve, undo
    }

    /// The rows the arrow keys move through, top to bottom.
    var navigableRows: [String] {
        sections.flatMap { $0.items.map(\.id) }
    }

    func navigate(_ key: NavigationKey) {
        if key == .undo {
            if !undoMove() { NSSound.beep() }
            return
        }
        let rows = navigableRows
        guard !rows.isEmpty else { return }
        let index = selectedRow.flatMap { rows.firstIndex(of: $0) }
        switch key {
        case .down:
            expandedRow = nil  // moving on closes the row that was opened out
            selectedRow = rows[index.map { min($0 + 1, rows.count - 1) } ?? 0]
        case .up:
            expandedRow = nil
            selectedRow = rows[index.map { max($0 - 1, 0) } ?? rows.count - 1]
        case .right:
            if index != nil { expandedRow = selectedRow }
        case .left:
            if expandedRow != nil, expandedRow == selectedRow { expandedRow = nil }
        case .activate:
            if let row = selectedRow, index != nil { toggleExpanded(row) }
        case .open:
            if let item = item(selectedRow) { openInPlane(item) }
        case .approve:
            if let item = item(selectedRow) { approve(item) }
        case .undo:
            break
        }
    }

    func toggleExpanded(_ id: String) {
        expandedRow = expandedRow == id ? nil : id
    }

    // MARK: Banners

    static let bannerAnimation = Animation.spring(response: 0.38, dampingFraction: 0.82)

    func show(_ notice: Notice) {
        withAnimation(Self.bannerAnimation) {
            banners.removeAll { $0.item.id == notice.item.id }
            banners.append(notice)
        }
        if banners.count > 4 { dismiss(banners[0]) }
        startTimer(for: notice)
    }

    func dismiss(_ notice: Notice) {
        bannerTimers[notice.id]?.cancel()
        bannerTimers[notice.id] = nil
        withAnimation(.easeIn(duration: 0.22)) {
            banners.removeAll { $0.id == notice.id }
        }
    }

    /// Holds a banner while the pointer is over it, and starts its time again afterwards.
    func hold(_ notice: Notice, _ held: Bool) {
        if held {
            bannerTimers[notice.id]?.cancel()
        } else {
            startTimer(for: notice)
        }
    }

    private func startTimer(for notice: Notice) {
        bannerTimers[notice.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss(notice) }
        bannerTimers[notice.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bannerSeconds, execute: work)
    }

    // MARK: Launch at login

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
    }
}
