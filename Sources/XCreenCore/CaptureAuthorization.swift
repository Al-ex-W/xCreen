import Foundation

/// One capture epoch. Revocation and the entire synchronous store mutation
/// share a lock: revocation waits for an already admitted commit, and no later
/// commit can start. Never hold this lock across an await or call back into it.
public final class CaptureAuthorization: @unchecked Sendable {
    public enum Revoked: Error { case invalidated }
    private let lock = NSLock()
    private var valid = true
    private var finalized = false
    public var didFinalize: Bool { lock.lock(); defer { lock.unlock() }; return finalized }
    public func finalize<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard valid, !finalized else { throw Revoked.invalidated }
        let value = try body()
        finalized = true
        return value
    }
    public init() {}
    public func invalidate() { lock.lock(); defer { lock.unlock() }; valid = false }
    public var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    public func withAuthorization<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard valid, !finalized else { throw Revoked.invalidated }
        return try body()
    }
}
