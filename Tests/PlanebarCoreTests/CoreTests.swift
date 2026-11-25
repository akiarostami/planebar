import Foundation
import Testing
@testable import PlanebarCore

private func state(_ id: String, _ name: String, _ group: String, _ sequence: Double, triage: Bool? = nil) -> PlaneState {
    PlaneState(id: id, name: name, group: group, sequence: sequence, isTriage: triage)
}

/// A project's states, deliberately out of order.
private let states = [
    state("done", "Done", "completed", 45000),
    state("backlog", "Backlog", "backlog", 15000),
    state("review", "Review", "started", 40000),
    state("cancelled", "Cancelled", "cancelled", 41000),
    state("todo", "Todo", "unstarted", 25000),
    state("progress", "In Progress", "started", 35000.5),
    state("triage", "Triage", "triage", 37000, triage: true),
]

@Suite struct NextStateTests {
    @Test func movesToNextBySequence() {
        #expect(Workflow.nextState(after: "todo", in: states)?.id == "progress")
        #expect(Workflow.nextState(after: "backlog", in: states)?.id == "todo")
    }

    @Test func skipsCancelledAndTriage() {
        // Review (40000) is followed by Cancelled (41000), then Done (45000).
        #expect(Workflow.nextState(after: "review", in: states)?.id == "done")
        // In Progress (35000.5) is followed by Triage (37000), then Review.
        #expect(Workflow.nextState(after: "progress", in: states)?.id == "review")
    }

    @Test func lastStateHasNone() {
        #expect(Workflow.nextState(after: "done", in: states) == nil)
        // Only Cancelled lies beyond it.
        let short = [state("a", "A", "started", 1), state("x", "X", "cancelled", 2)]
        #expect(Workflow.nextState(after: "a", in: short) == nil)
        #expect(Workflow.nextState(after: "unknown", in: states) == nil)
    }

    @Test func floatSequences() {
        let close = [state("a", "A", "started", 1.25), state("b", "B", "started", 1.5), state("c", "C", "started", 1.375)]
        #expect(Workflow.nextState(after: "a", in: close)?.id == "c")
        #expect(Workflow.nextState(after: "c", in: close)?.id == "b")
    }
}

@Suite struct PhaseTests {
    @Test func unionOrderedBySequence() {
        let other = [state("o1", "Review", "started", 30000), state("o2", "QA", "started", 38000), state("o3", "Todo", "unstarted", 25000)]
        let phases = Workflow.phases([states, other])
        #expect(phases.map(\.name) == ["Backlog", "Todo", "Review", "In Progress", "QA", "Cancelled", "Done"])
        #expect(phases.first { $0.name == "Review" }?.sequence == 30000)  // the lowest wins
    }
}

@Suite struct QueryTests {
    @Test func pql() {
        let text = Workflow.pql(phases: ["Review", "Todo"], projectIDs: ["p-1", "p-2"])
        #expect(text == #"state IN ("Review", "Todo") AND project IN ("p-1", "p-2")"#)
    }

    @Test func escaping() {
        #expect(Workflow.quote(#"Say "hi""#) == #""Say \"hi\"""#)
        #expect(Workflow.quote(#"a\b"#) == #""a\\b""#)
    }

    @Test func urlEncoding() {
        #expect(Workflow.encodeQueryValue(#"state IN ("A+B") & x=1"#)
            == "state%20IN%20%28%22A%2BB%22%29%20%26%20x%3D1")
        #expect(Workflow.encodeQueryValue("Révision") == "R%C3%A9vision")
        #expect(Workflow.encodeQueryValue("state,project") == "state%2Cproject")
        #expect(Workflow.browseURL(workspace: "acme", key: "SHOP-57")?.absoluteString
            == "https://app.plane.so/acme/browse/SHOP-57/")
    }
}

private let sample = #"""
{"grouped_by":null,"total_count":3,"next_cursor":"100:1:0","next_page_results":false,"results":[
 {"id":"i1","name":"Group select in mail lists","sequence_id":299,"priority":"none","labels":["l1"],
  "description_stripped":"  Anywhere there is a mail list.\n ","description_html":"<p>Anywhere</p>",
  "updated_at":"2026-11-24T17:12:43.951797-08:00","created_at":"2026-11-20T09:00:00Z","parent":null,
  "state_group":"started","min_module_name":null,
  "state":{"id":"s-review","name":"Review","group":"started","color":"#8B5CF6"},
  "project":{"id":"p-shop","identifier":"SHOP","name":"Storefront","emoji":null}},
 {"id":"i2","name":"Delete account with a subscription","sequence_id":117,"priority":"medium","labels":[],
  "description_stripped":null,"updated_at":"2026-11-24T10:05:33.796805-08:00","created_at":"2026-11-01T00:00:00.5Z",
  "state_group":"started","min_module_name":"Web app",
  "state":{"id":"s-doc-review","name":"Review","group":"started","color":"#8B5CF6"},
  "project":{"id":"p-bill","identifier":"BILL","name":"Billing"}},
 {"id":"i3","name":"Unexpanded","sequence_id":5,"labels":[],"state":"s-x","project":"p-shop","state_group":"unstarted",
  "updated_at":"2026-11-24T08:00:00-08:00"}
]}
"""#

private func items() throws -> [WorkItem] {
    try JSONDecoder().decode(Page<WorkItem>.self, from: Data(sample.utf8)).results
}

@Suite struct DecodingTests {
    @Test func expandedObjects() throws {
        let list = try items()
        #expect(list.count == 3)
        #expect(list[0].key == "SHOP-299")
        #expect(list[0].project.name == "Storefront" && list[0].state.name == "Review" && list[0].state.color == "#8B5CF6")
        #expect(list[0].description == "Anywhere there is a mail list.")
        #expect(list[0].labels == ["l1"])
        let utc = PlaneDate.parse("2026-11-25T01:12:43Z")!
        #expect(abs(list[0].updatedAt!.timeIntervalSince(utc) - 0.95) < 0.01)
        #expect(list[1].moduleName == "Web app" && list[1].priority == "medium" && list[1].description == "")
        #expect(list[1].createdAt != nil)
        // Without the expansion, only ids.
        #expect(list[2].project.id == "p-shop" && list[2].project.identifier == "" && list[2].state.id == "s-x")
        #expect(list[2].state.group == "unstarted" && list[2].priority == "none")
    }

    @Test func dates() {
        let micro = PlaneDate.parse("2026-11-24T17:12:43.951797-08:00")
        let plain = PlaneDate.parse("2026-11-25T01:12:43Z")
        #expect(micro != nil && plain != nil)
        #expect(abs(micro!.timeIntervalSince(plain!) - 0.951797) < 0.01)
        #expect(PlaneDate.parse("yesterday") == nil)
    }

    @Test func bareListAndDictBothDecode() throws {
        let bare = try JSONDecoder().decode(Page<PlaneProject>.self, from: Data(#"[{"id":"p","identifier":"SHOP","name":"Storefront"}]"#.utf8))
        #expect(bare.results.map(\.identifier) == ["SHOP"] && !bare.hasNext)
        let dict = try JSONDecoder().decode(Page<PlaneState>.self, from: Data(##"{"results":[{"id":"s","name":"Review","group":"started","sequence":40000.0,"color":"#8B5CF6","is_triage":false}],"next_page_results":true,"next_cursor":"100:1:0"}"##.utf8))
        #expect(dict.results.first?.sequence == 40000 && dict.hasNext && dict.nextCursor == "100:1:0")
    }
}

@Suite struct GroupingTests {
    private func item(_ id: String, _ project: String, _ phase: String, _ seq: Int, minutesAgo: Double) -> WorkItem {
        WorkItem(id: id, name: id, sequenceID: seq, updatedAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
                 project: .init(id: "p-" + project, identifier: project, name: project),
                 state: .init(id: project + phase, name: phase, group: "started"))
    }

    @Test func byPhaseThenProject() {
        let phases = [Phase(name: "Todo", sequence: 25000, group: "unstarted"),
                      Phase(name: "Review", sequence: 40000, group: "started"),
                      Phase(name: "QA", sequence: 42000, group: "started")]
        let list = [
            item("a", "BILL", "Review", 133, minutesAgo: 5),
            item("b", "SHOP", "Review", 296, minutesAgo: 60),
            item("c", "SHOP", "Review", 299, minutesAgo: 1),
            item("d", "SHOP", "Todo", 10, minutesAgo: 1),
            item("e", "NEG", "Done", 1, minutesAgo: 1),   // not a watched phase
        ]
        let sections = Workflow.sections(list, phases: phases, projectOrder: ["p-DOC", "p-CAS"])
        #expect(sections.map(\.phase.name) == ["Todo", "Review"])  // QA is empty
        #expect(sections[1].count == 3)
        #expect(sections[1].projects.map(\.project.identifier) == ["BILL", "SHOP"])
        #expect(sections[1].projects[1].items.map(\.id) == ["c", "b"])  // most recent first
        #expect(sections[1].items.map(\.id) == ["a", "c", "b"])
    }

    @Test func arrivals() {
        let old = [item("a", "SHOP", "Review", 1, minutesAgo: 1), item("b", "SHOP", "Todo", 2, minutesAgo: 1)]
        let new = [item("a", "SHOP", "Review", 1, minutesAgo: 1), item("b", "SHOP", "Review", 2, minutesAgo: 1),
                   item("c", "SHOP", "Review", 3, minutesAgo: 1)]
        #expect(Workflow.arrivals(old: old, new: new).map(\.id) == ["b", "c"])
    }
}
