import Testing
@testable import LayXCore

@Suite struct PromptCacheIndexTests {
    let system = Array(0..<100)

    @Test func conversationCacheIsTakenExclusively() {
        var idx = PromptCacheIndex<String>(budgetBytes: 1000)
        idx.insert(key: "chat-1", tokens: system + [7, 8, 9], bytes: 10, payload: "A")
        let m = idx.take(key: "chat-1", prompt: system + [7, 8, 9, 10, 11])
        #expect(m?.entry.payload == "A")
        #expect(m?.shared == 103)
        #expect(m?.exclusive == true)
        #expect(idx.entries.isEmpty, "taken caches leave the index (one owner at a time)")
    }

    @Test func atLeastOneTokenIsAlwaysPrefilled() {
        var idx = PromptCacheIndex<String>(budgetBytes: 1000)
        idx.insert(key: "k", tokens: [1, 2, 3], bytes: 1, payload: "A")
        #expect(idx.take(key: "k", prompt: [1, 2, 3])?.shared == 2)
    }

    @Test func prefixCacheIsSharedNotTaken() {
        var idx = PromptCacheIndex<String>(budgetBytes: 1000)
        idx.insert(key: "chat-1", tokens: system + [5, 5], bytes: 10, payload: "A")
        let m = idx.take(key: "chat-2", prompt: system + [9, 9, 9])
        #expect(m?.shared == 100)
        #expect(m?.exclusive == false)
        #expect(idx.entries.count == 1)
        #expect(idx.take(key: "chat-3", prompt: Array(0..<10) + [42], minShared: 32) == nil, "short overlaps aren't worth copying")
    }

    @Test func exactOnlySkipsEntriesThatWouldNeedRewinding() {
        var idx = PromptCacheIndex<String>(budgetBytes: 1000)
        idx.insert(key: "prefix", tokens: system, bytes: 1, payload: "P")            // exact prefix of the prompt
        idx.insert(key: "other", tokens: system + [1, 2, 3], bytes: 1, payload: "O")  // diverges after system
        let m = idx.take(key: "mine", prompt: system + [9, 9], exactOnly: true)
        #expect(m?.entry.payload == "P")
        #expect(m?.shared == 100)
        let rewindable = idx.take(key: "mine", prompt: system + [1, 2, 9], exactOnly: false)
        #expect(rewindable?.entry.payload == "O" && rewindable?.shared == 102)
    }

    @Test func lruEvictionWithinBudget() {
        var idx = PromptCacheIndex<String>(budgetBytes: 25)
        idx.insert(key: "a", tokens: [1], bytes: 10, payload: "A")
        idx.insert(key: "b", tokens: [2], bytes: 10, payload: "B")
        _ = idx.take(key: nil, prompt: Array(repeating: 2, count: 40), minShared: 1)  // touches b
        let evicted = idx.insert(key: "c", tokens: [3], bytes: 10, payload: "C")
        #expect(evicted == ["A"])
        #expect(Set(idx.entries.compactMap(\.key)) == ["b", "c"])
        #expect(idx.insert(key: "huge", tokens: [4], bytes: 100, payload: "H") == ["H"], "never stores more than the budget")
    }

    @Test func removalAndBudgetChanges() {
        var idx = PromptCacheIndex<String>(budgetBytes: 100)
        idx.insert(key: "a", tokens: [1], bytes: 30, payload: "A")
        idx.insert(key: "b", tokens: [2], bytes: 30, payload: "B")
        #expect(idx.remove(key: "a") == ["A"])
        #expect(idx.setBudget(10) == ["B"])
        idx.insert(key: "c", tokens: [3], bytes: 5, payload: "C")
        #expect(idx.removeAll() == ["C"])
        #expect(idx.totalBytes == 0)
        #expect(PromptCacheIndex<String>(budgetBytes: 0).budgetBytes == 0)
        var off = PromptCacheIndex<String>(budgetBytes: 0)
        #expect(off.insert(key: "x", tokens: [1], bytes: 1, payload: "X") == ["X"], "budget 0 disables caching")
    }

    @Test func replacingAKeyReturnsTheOldPayload() {
        var idx = PromptCacheIndex<String>(budgetBytes: 100)
        idx.insert(key: "a", tokens: [1], bytes: 1, payload: "old")
        #expect(idx.insert(key: "a", tokens: [1, 2], bytes: 1, payload: "new") == ["old"])
        #expect(idx.entries.map(\.payload) == ["new"])
    }
}
