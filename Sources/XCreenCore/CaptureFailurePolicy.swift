/// Only acquisition availability failures may retry. Every retry goes through all
/// permission/session/foreground gates again, with the active clock paused.
public enum CaptureFailurePolicy {
    public enum Failure { case noForegroundWindow, screenCaptureTransient, permissionOrSession, storageOrOCR }
    public enum Action { case retryGap, safetyBlock }
    public static func action(_ failure: Failure) -> Action {
        switch failure {
        case .noForegroundWindow, .screenCaptureTransient: return .retryGap
        case .permissionOrSession, .storageOrOCR: return .safetyBlock
        }
    }
}
