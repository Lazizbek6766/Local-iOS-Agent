import Testing
@testable import LocalIOSAgent

@Suite("Output sanitizer")
struct OutputSanitizerTests {
    @Test("Removes ANSI colors and carriage returns")
    func removesControlSequences() {
        let input = "\u{001B}[31mError\u{001B}[0m\r\n"
        #expect(OutputSanitizer.clean(input) == "Error\n")
    }

    @Test("Preserves ordinary Unicode text")
    func preservesUnicode() {
        let input = "Loyiha muvaffaqiyatli qurildi ✅"
        #expect(OutputSanitizer.clean(input) == input)
    }
}
