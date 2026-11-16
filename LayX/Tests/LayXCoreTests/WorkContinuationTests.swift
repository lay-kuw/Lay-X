import Testing
@testable import LayXCore

@Suite("Work continuation")
@MainActor
struct WorkContinuationTests {
    @Test func plainAppend() {
        #expect(WorkSession.joinContinuation("<<<FILE a.swift\nlet a = 1\nlet b", " = 2\nFILE>>>") == "<<<FILE a.swift\nlet a = 1\nlet b = 2\nFILE>>>")
    }

    @Test func overlapIsRemoved() {
        let prev = "<<<FILE a.swift\nfunc hello() {\n    print(\"hi\")\n"
        let next = "    print(\"hi\")\n}\nFILE>>>"
        #expect(WorkSession.joinContinuation(prev, next) == "<<<FILE a.swift\nfunc hello() {\n    print(\"hi\")\n}\nFILE>>>")
    }

    @Test func restartedBlockReplacesPartial() {
        let prev = "Summary.\n<<<FILE b.swift\nfull\nFILE>>>\n<<<FILE a.swift\nhalf"
        let next = "\n<<<FILE a.swift\nwhole file\nFILE>>>"
        let joined = WorkSession.joinContinuation(prev, next)
        #expect(joined == "Summary.\n<<<FILE b.swift\nfull\nFILE>>>\n<<<FILE a.swift\nwhole file\nFILE>>>")
        #expect(ProposalParser.parse(joined).blocks.map(\.path) == ["b.swift", "a.swift"])
    }

    @Test func lineAlignedResume() {
        let partial = "<<<FILE a.swift\nlet a = 1\nfunc farewell(name:"
        let aligned = WorkSession.lineAligned(partial)
        #expect(aligned == "<<<FILE a.swift\nlet a = 1\n")
        #expect(WorkSession.joinContinuation(aligned, "let a = 1\nfunc farewell(name: String) {}\nFILE>>>")
                == "<<<FILE a.swift\nlet a = 1\nfunc farewell(name: String) {}\nFILE>>>")
        #expect(WorkSession.joinContinuation(aligned, "func farewell(name: String) {}\nFILE>>>")
                == "<<<FILE a.swift\nlet a = 1\nfunc farewell(name: String) {}\nFILE>>>")
    }

    @Test func emptyPrevious() {
        #expect(WorkSession.joinContinuation("", "abc") == "abc")
    }
}
