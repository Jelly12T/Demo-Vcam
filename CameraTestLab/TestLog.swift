import Foundation

struct TestLogEntry {
    let timestamp: Date
    let sourceKind: String
    let verdict: String
    let score: Double
    let format: String
    let resolution: String
    let hasIntrinsics: Bool

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var line: String {
        String(format: "[%@] source=%@ verdict=%@ score=%.2f fmt=%@ res=%@ intrinsics=%@",
               Self.formatter.string(from: timestamp),
               sourceKind, verdict, score, format, resolution, hasIntrinsics ? "yes" : "no")
    }
}
