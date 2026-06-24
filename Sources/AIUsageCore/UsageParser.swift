import Foundation

public enum UsageParser {
    public static func parsePercentUsed(from text: String) -> Int? {
        let patterns = [
            #"(?i)(?:used|usage|quota|limit)[^0-9]{0,24}([0-9]{1,3})\s*%"#,
            #"([0-9]{1,3})\s*%"#
        ]

        for pattern in patterns {
            if let value = firstMatch(in: text, pattern: pattern) {
                return min(100, max(0, value))
            }
        }

        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
            return nil
        }

        let valueRange = match.range(at: 1)
        guard let swiftRange = Range(valueRange, in: text) else {
            return nil
        }

        return Int(text[swiftRange])
    }
}
