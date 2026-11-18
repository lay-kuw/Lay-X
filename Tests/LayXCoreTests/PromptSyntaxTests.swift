import Foundation
import Testing
@testable import LayXCore

struct DynamicPromptTests {
    @Test func plainTextIsUnchanged() {
        #expect(DynamicPrompt.expand("a cat, (red:1.2)", seed: 1).text == "a cat, (red:1.2)")
        #expect(!DynamicPrompt.hasSyntax("a cat"))
    }

    @Test func picksOneOptionReproducibly() {
        let options: Set = ["a red cat", "a green cat", "a blue cat"]
        var seen = Set<String>()
        for seed in 0..<64 as Range<UInt64> {
            let text = DynamicPrompt.expand("a {red|green|blue} cat", seed: seed).text
            #expect(options.contains(text))
            #expect(DynamicPrompt.expand("a {red|green|blue} cat", seed: seed).text == text)
            seen.insert(text)
        }
        #expect(seen == options)
    }

    @Test func nestedAndEmptyOptions() {
        for seed in 0..<32 as Range<UInt64> {
            let text = DynamicPrompt.expand("{a {x|y}|}b", seed: seed).text
            #expect(["a xb", "a yb", "b"].contains(text))
        }
    }

    @Test func weightsSteerThePick() {
        for seed in 0..<32 as Range<UInt64> {
            #expect(DynamicPrompt.expand("{0::never|1::always}", seed: seed).text == "always")
        }
    }

    @Test func multiplePicksAreDistinct() {
        for seed in 0..<32 as Range<UInt64> {
            let parts = DynamicPrompt.expand("{2$$a|b|c}", seed: seed).text.components(separatedBy: ", ")
            #expect(parts.count == 2 && Set(parts).count == 2)
            let custom = DynamicPrompt.expand("{3$$ and $$a|b|c}", seed: seed).text
            #expect(Set(custom.components(separatedBy: " and ")) == ["a", "b", "c"])
            let ranged = DynamicPrompt.expand("{1-$$a|b|c}", seed: seed).text.components(separatedBy: ", ")
            #expect((1...3).contains(ranged.count))
        }
    }

    @Test func escapesStayLiteral() {
        #expect(DynamicPrompt.expand(#"\{a\|b\} \(c\)"#, seed: 3).text == #"{a|b} \(c\)"#)
    }

    @Test func wildcardsExpandRecursively() {
        let files = ["color": ["{light|dark} red"], "pets/cat": ["__color__ cat"]]
        let r = DynamicPrompt.expand("a __pets/cat__ and __missing__", seed: 9, wildcards: { files[$0] })
        #expect(r.text == "a light red cat and __missing__" || r.text == "a dark red cat and __missing__")
        #expect(r.missingWildcards == ["missing"])
        // Not a wildcard: spaces, or no closing marker.
        #expect(DynamicPrompt.expand("a__b c__d __e", seed: 1).text == "a__b c__d __e")
    }

    @Test func wildcardFilesStayInTheirFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lx-wild-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# comment\nred\n\n  blue  \n".write(to: dir.appendingPathComponent("sub/colors.txt"), atomically: true, encoding: .utf8)
        let library = WildcardLibrary(folder: dir)
        #expect(library.lines("sub/colors") == ["red", "blue"])
        #expect(library.lines("../colors") == nil)
        #expect(library.lines("nope") == nil)
    }
}

struct PromptWeightingTests {
    func pairs(_ text: String) -> [String] {
        PromptWeighting.parse(text).map { "\($0.text)@\(String(format: "%.3f", $0.weight))" }
    }

    @Test func a1111Syntax() {
        #expect(pairs("a cat") == ["a cat@1.000"])
        #expect(pairs("a (cat)") == ["a @1.000", "cat@1.100"])
        #expect(pairs("((cat))") == ["cat@1.210"])
        #expect(pairs("[cat] dog") == ["cat@0.909", " dog@1.000"])
        #expect(pairs("(cat:1.5), dog") == ["cat@1.500", ", dog@1.000"])
        #expect(pairs("(a (b:2) c:0.5)") == ["a @0.500", "b@1.000", " c@0.500"])
        #expect(pairs(#"\(cat\)"#) == ["(cat)@1.000"])
        #expect(pairs("(unclosed") == ["unclosed@1.100"])
        #expect(pairs("time: 12:30)") == ["time: 12:30)@1.000"])
    }

    @Test func languageModelPromptsKeepOrdinaryBrackets() {
        #expect(PromptWeighting.stripExplicitWeights("a sign (OPEN), (cat:1.3)") == "a sign (OPEN), cat")
        #expect(PromptWeighting.stripExplicitWeights(#"\(x\) ((y:1.2))"#) == "(x) (y)")
        #expect(PromptWeighting.stripExplicitWeights("plain") == "plain")
        #expect(PromptWeighting.forLanguageModel("a cat BREAK (red:1.2) sky") == "a cat, red sky")
        #expect(PromptWeighting.forLanguageModel("a cat, BREAK, sky BREAK") == "a cat, sky")
        #expect(PromptWeighting.forLanguageModel("BREAKFAST") == "BREAKFAST")
    }
}
