import Foundation
public struct WindowCandidate {
    public let id: UInt32
    public let pid: Int32
    public let layer: Int
    public let width: Double
    public let height: Double
    public init(id: UInt32, pid: Int32, layer: Int, width: Double, height: Double) { self.id = id; self.pid = pid; self.layer = layer; self.width = width; self.height = height }
}
public enum WindowSelection {
    public static func frontmost(_ windows: [WindowCandidate], pid: Int32) -> UInt32? {
        windows.first {
            $0.pid == pid && $0.layer == 0 &&
            $0.width.isFinite && $0.height.isFinite &&
            $0.width > 1 && $0.height > 1 &&
            $0.width <= 16_384 && $0.height <= 16_384
        }?.id
    }
}
