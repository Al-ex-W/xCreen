import Foundation
import CoreFoundation

public struct BatchEffectReceipt: Codable, Sendable {
    public let entryID: String
    public let day: String?
    public let digest: String?
    public let state: String
    enum CodingKeys: String, CodingKey { case entryID = "entry_id", day, digest, state }
}

/// Host-issued processing evidence, never derived from assistant prose or history.
public struct BatchReceipt: Codable, Sendable {
    public let batchID: String
    public let sourceIDs: [String]
    public let sessionID: String
    public let status: String
    public let verified: Bool
    public let effectCount: Int
    public let effects: [BatchEffectReceipt]
    /// Optional for compatibility: old hosts can never authorize replay.
    public let retrySafe: Bool?

    public init(data: Data, batchID: String, sourceIDs: [String], sessionID: String) throws {
        guard data.count <= 48_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["batch_id"] as? String == batchID,
              let sources = object["source_ids"] as? [String], sources.sorted() == sourceIDs.sorted(), Set(sources).count == sources.count,
              object["session_id"] as? String == sessionID,
              let status = object["status"] as? String, ["saved", "skipped", "missing", "uncertain"].contains(status),
              let flag = object["verified"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(),
              let effects = object["effects"] as? [[String: Any]] else { throw HermesGatewayError.protocolFailure }
        if flag.boolValue {
            guard (status == "saved" && !effects.isEmpty) || (status == "skipped" && effects.isEmpty) else { throw HermesGatewayError.protocolFailure }
            let ids = effects.compactMap { $0["entry_id"] as? String }
            guard ids.count == effects.count, Set(ids).count == ids.count,
                  effects.allSatisfy({ $0["state"] as? String == "completed" }) else { throw HermesGatewayError.protocolFailure }
        }
        self.batchID = batchID; self.sourceIDs = sources.sorted(); self.sessionID = sessionID
        self.effects = try effects.map { item in
            guard let id = item["entry_id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                  let state = item["state"] as? String, ["completed", "pending", "uncertain"].contains(state),
                  (item["day"] as? String)?.utf8.count ?? 0 <= 32,
                  (item["digest"] as? String)?.utf8.count ?? 0 <= 128 else { throw HermesGatewayError.protocolFailure }
            return BatchEffectReceipt(entryID: id, day: item["day"] as? String, digest: item["digest"] as? String, state: state)
        }
        if let retry = object["retry_safe"] {
            guard let boolean = retry as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID(),
                  !boolean.boolValue || (!flag.boolValue && status == "uncertain" && effects.isEmpty) else { throw HermesGatewayError.protocolFailure }
            retrySafe = boolean.boolValue
        } else { retrySafe = nil }
        self.status = status; self.verified = flag.boolValue; self.effectCount = effects.count
    }
    public var completesProcessing: Bool { verified && (status == "saved" || status == "skipped") }
}

public struct BatchBinding: Codable, Sendable {
    public let batchID: String
    public let sourceIDs: [String]
    public let sessionID: String?
    public init(batchID: String, sourceIDs: [String], sessionID: String? = nil) { self.batchID = batchID; self.sourceIDs = sourceIDs.sorted(); self.sessionID = sessionID }
}
