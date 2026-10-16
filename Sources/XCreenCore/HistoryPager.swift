import Foundation

/// Bounded snapshots of host-owned history, never a second transcript database.
/// Cursors identify a frozen snapshot and offset; stale/evicted cursors fail explicitly.
public struct HistoryPager {
    private var snapshots: [String: [[String: Any]]] = [:]
    private var order: [String] = []
    public init() {}

    public mutating func page(data: Data?, cursor: String?, limit: Int = 20) throws -> Data {
        guard (1...20).contains(limit) else { throw LocalControlError.invalidRequest("history limit must be 1...20") }
        let key: String, offset: Int
        if let cursor {
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, let value = Int(parts[1]), value >= 0, snapshots[String(parts[0])] != nil else { throw LocalControlError.invalidRequest("stale or invalid history cursor") }
            key = String(parts[0]); offset = value
        } else {
            guard let data, data.count <= 1_048_576, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["messages"] as? [[String: Any]] else { throw HermesGatewayError.protocolFailure }
            key = UUID().uuidString; offset = 0
            snapshots[key] = try rows.map { row in
                let safe = Self.sanitize(row) as? [String: Any] ?? [:]
                if try JSONSerialization.data(withJSONObject: safe).count > 8_000 {
                    return ["role": String((row["role"] as? String ?? "unknown").prefix(32)), "oversized": true, "content": "[oversized message omitted]", "pixels_removed": true]
                }
                return safe
            }
            order.append(key)
            while order.count > 4 { snapshots.removeValue(forKey: order.removeFirst()) }
        }
        guard let rows = snapshots[key], offset <= rows.count else { throw LocalControlError.invalidRequest("invalid history offset") }
        var selected: [[String: Any]] = [], end = offset
        while end < rows.count && selected.count < limit {
            let candidate = selected + [rows[end]]
            if try JSONSerialization.data(withJSONObject: candidate).count > 40_000 { break }
            selected = candidate; end += 1
        }
        let more = end < rows.count
        let result: [String: Any] = ["messages": selected, "has_more": more, "next_cursor": more ? "\(key):\(end)" as Any : NSNull(), "pixels_removed": true]
        let output = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        guard output.count <= 48_000 else { throw HermesGatewayError.protocolFailure }
        return output
    }
    private static func sanitize(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 20 else { return "[nested content omitted]" }
        if let object = value as? [String: Any] {
            if ["image", "image_url", "input_image"].contains(object["type"] as? String ?? "") { return ["type": "image_omitted"] }
            let blocked = Set(["image_url", "images", "attachments", "content_base64", "base64", "image_data", "data", "file_path", "fileURL"])
            return object.reduce(into: [String: Any]()) { result, pair in
                if !blocked.contains(pair.key) { result[pair.key] = sanitize(pair.value, depth: depth + 1) }
            }
        }
        if let array = value as? [Any] { return array.map { sanitize($0, depth: depth + 1) } }
        if let text = value as? String {
            return text.replacingOccurrences(of: "data:image/[^\\s\\\"<>]+", with: "[image omitted]", options: .regularExpression)
        }
        return value
    }
}
