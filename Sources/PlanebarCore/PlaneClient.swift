import Foundation

public enum PlaneError: Error, Equatable, Sendable {
    case badKey
    case forbidden
    case notFound
    /// Too many requests; wait this long, when Plane says.
    case rateLimited(retryAfter: TimeInterval?)
    case server(Int)
    case network(String)
    case decoding(String)

    /// One short sentence for the menu and Settings.
    public var message: String {
        switch self {
        case .badKey: return "Plane refused the API key."
        case .forbidden: return "The key has no access to this workspace."
        case .notFound: return "Workspace not found."
        case .rateLimited: return "Plane is limiting requests; trying again shortly."
        case .server(let code): return "Plane answered with error \(code)."
        case .network(let reason): return "Plane is unreachable: \(reason)"
        case .decoding: return "Plane's answer could not be read."
        }
    }
}

/// What Planebar asks of Plane. The real client and demo mode both provide it.
public protocol PlaneService: Sendable {
    func projects() async throws -> [PlaneProject]
    func states(project: String) async throws -> [PlaneState]
    func labels(project: String) async throws -> [PlaneLabel]
    /// Items in any of the phases (state names) in any of the projects (ids).
    func workItems(phases: [String], projectIDs: [String]) async throws -> [WorkItem]
    func setState(project: String, item: String, state: String) async throws
}

/// Plane's REST API, v1, for one workspace.
public struct PlaneClient: PlaneService {
    public var key: String
    public var workspace: String
    public var session: URLSession

    public static let host = "https://api.plane.so/api/v1"

    public init(key: String, workspace: String, session: URLSession = .shared) {
        self.key = key
        self.workspace = workspace
        self.session = session
    }

    private var base: String { "\(Self.host)/workspaces/\(Workflow.encodeQueryValue(workspace))" }

    public func projects() async throws -> [PlaneProject] {
        try await list("/projects/")
    }

    public func states(project: String) async throws -> [PlaneState] {
        try await list("/projects/\(project)/states/")
    }

    public func labels(project: String) async throws -> [PlaneLabel] {
        try await list("/projects/\(project)/labels/")
    }

    public func workItems(phases: [String], projectIDs: [String]) async throws -> [WorkItem] {
        guard !phases.isEmpty, !projectIDs.isEmpty else { return [] }
        let pql = Workflow.pql(phases: phases, projectIDs: projectIDs)
        return try await list("/work-items/", query: [("expand", "state,project"), ("pql", pql)])
    }

    public func setState(project: String, item: String, state: String) async throws {
        var request = request(path: "/projects/\(project)/work-items/\(item)/", query: [])
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["state": state])
        _ = try await send(request)
    }

    /// Every page of a list, following `next_cursor`. Stops after 20 pages.
    private func list<T: Decodable>(_ path: String, query: [(String, String)] = []) async throws -> [T] {
        var all: [T] = []
        var cursor: String?
        for _ in 0..<20 {
            var items = [("per_page", "100")] + query
            if let cursor { items.append(("cursor", cursor)) }
            let data = try await send(request(path: path, query: items))
            let page: Page<T>
            do {
                page = try JSONDecoder().decode(Page<T>.self, from: data)
            } catch {
                throw PlaneError.decoding(String(describing: error))
            }
            all += page.results
            guard page.hasNext, let next = page.nextCursor, next != cursor else { break }
            cursor = next
        }
        return all
    }

    private func request(path: String, query: [(String, String)]) -> URLRequest {
        let queryText = query.map { "\($0.0)=\(Workflow.encodeQueryValue($0.1))" }.joined(separator: "&")
        let url = URL(string: base + path + (queryText.isEmpty ? "" : "?" + queryText))!
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PlaneError.network((error as? URLError)?.localizedDescription ?? error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw PlaneError.badKey
        case 403: throw PlaneError.forbidden
        case 404: throw PlaneError.notFound
        case 429:
            let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw PlaneError.rateLimited(retryAfter: retry)
        default: throw PlaneError.server(status)
        }
    }
}
