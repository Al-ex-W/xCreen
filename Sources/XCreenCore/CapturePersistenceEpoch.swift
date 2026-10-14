import Foundation

/// Main-actor checkpoint ownership, paired with the store's synchronous commit
/// capability. No await occurs during epoch replacement or completion delivery.
@MainActor
public final class CapturePersistenceEpoch {
    public private(set) var generation: UInt64 = 0
    public private(set) var authorization = CaptureAuthorization()
    public var checkpoint = CaptureCheckpoint()
    public init() {}
    public func advance() {
        authorization.invalidate()
        if authorization.didFinalize { checkpoint = CaptureCheckpoint() }
        authorization = CaptureAuthorization()
        generation &+= 1
    }
    @discardableResult
    public func complete(_ token: CaptureAuthorization, deliver: () -> Void) -> Bool {
        guard token === authorization, token.isValid, token.didFinalize else { return false }
        advance()
        deliver()
        return true
    }
}
