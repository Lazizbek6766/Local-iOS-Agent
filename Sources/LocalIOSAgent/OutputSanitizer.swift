import Foundation

enum OutputSanitizer {
    private static let ansiPattern = "\\u001B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])"

    static func clean(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: ansiPattern) else {
            return value
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression
            .stringByReplacingMatches(in: value, range: range, withTemplate: "")
            .replacingOccurrences(of: "\r", with: "")
    }
}
