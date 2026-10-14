import Foundation

/// Local ordering policy around the one Hermes-owned session.  This is deliberately
/// transport-agnostic so privacy transitions can discard automatic work before any
/// provider request is made.
public enum SessionWork: Equatable, Sendable {
    case manual(id: String)
    case automatic(id: String)
}

public struct SessionCoordinator: Sendable {
    private var manual: [SessionWork] = []
    private var automatic: [SessionWork] = []
    private var integrity = false

    public init() {}

    public mutating func setIntegrity(_ enabled: Bool) {
        integrity = enabled
        if enabled { automatic.removeAll() }
    }

    public mutating func enqueue(_ work: SessionWork) {
        switch work {
        case .manual: manual.append(work)
        case .automatic where !integrity: automatic.append(work)
        case .automatic: break
        }
    }

    public mutating func next() -> SessionWork? {
        if !manual.isEmpty { return manual.removeFirst() }
        if !automatic.isEmpty { return automatic.removeFirst() }
        return nil
    }
}

public enum EvidencePathError: Error, Equatable {
    case invalidReference
}

/// Resolves UI attachment cards by an owned ID-derived filename, never an arbitrary
/// assistant-provided path. Callers must separately check file existence and expiry.
public struct EvidencePathResolver: Sendable {
    private let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }

    public func resolve(id: String, filename: String) throws -> URL {
        let safeID = id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil
        let safeName = filename.range(of: "^[A-Za-z0-9_-]{1,128}\\.(png|jpg|jpeg|heic)$", options: [.regularExpression, .caseInsensitive]) != nil
        guard safeID, safeName, filename.hasPrefix(id + ".") else { throw EvidencePathError.invalidReference }
        let candidate = root.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else { throw EvidencePathError.invalidReference }
        return candidate
    }
}
