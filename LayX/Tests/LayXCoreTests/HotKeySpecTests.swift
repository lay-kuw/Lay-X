import Testing
@testable import LayXCore

@Suite struct HotKeySpecTests {
    @Test func defaultIsOptionSpace() {
        #expect(HotKeySpec.default.displayString == "⌥Space")
        #expect(HotKeySpec.decode(nil) == .some(.default))
    }

    @Test func roundTripAndOff() {
        for spec in HotKeySpec.choices {
            #expect(HotKeySpec.decode(HotKeySpec.encode(spec)) == .some(spec))
        }
        #expect(HotKeySpec.decode("off") == .some(nil))
    }

    @Test func corruptOrInvalidValuesAreRejected() {
        #expect(HotKeySpec.decode("garbage") == nil)
        #expect(HotKeySpec.decode("512-49") == nil, "Shift+Space alone would hijack typing")
    }

    @Test func displayOrderFollowsMacConvention() {
        let s = HotKeySpec(keyCode: HotKeySpec.keyL, modifiers: HotKeySpec.cmd | HotKeySpec.shift | HotKeySpec.option | HotKeySpec.control)
        #expect(s.displayString == "⌃⌥⇧⌘L")
    }

    @Test func registrationStatusMapping() {
        let s = HotKeySpec.default
        #expect(HotKeyStatus.from(osStatus: 0, spec: s) == .registered(s))
        #expect(HotKeyStatus.from(osStatus: -9878, spec: s) == .conflict(s))
        #expect(HotKeyStatus.from(osStatus: -50, spec: s) == .failed(s, code: -50))
        #expect(HotKeyStatus.conflict(s).message.contains("already used"))
    }

    @Test func allChoicesAreValidAndUnique() {
        #expect(HotKeySpec.choices.allSatisfy { $0.isValid })
        #expect(Set(HotKeySpec.choices).count == HotKeySpec.choices.count)
    }
}
