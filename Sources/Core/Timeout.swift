import Foundation

public struct TimedOut: Error { public init() {} }

public enum Timeout {
    /// Waits for a callback-style answer, giving up after `seconds`. The first of answer/timeout wins;
    /// anything after that is ignored, so a late or repeated answer can never resume twice.
    public static func callback<T: Sendable>(seconds: Double,
                                             _ start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() { cont.resume(throwing: TimedOut()) }
            }
            start { result in if once.claim() { cont.resume(with: result) } }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }
}

/// Tells a stuck phone apart from edited versions it can't make. Lives for one connection: a replug starts a new one.
/// When the phone fails to make one edited version (IMG_E…), every edited version after it hangs too, until a replug,
/// so the rest are left for then. Two stored files hanging back to back mean the phone stopped answering.
public struct HangTracker {
    private var storedHangs = 0
    public private(set) var editsBlocked = false
    public init() {}
    public func shouldRead(_ item: PhoneItem) -> Bool { !(item.isEditedRender && editsBlocked) }
    public mutating func answered() { storedHangs = 0 }
    /// Returns true when the phone looks stuck.
    public mutating func timedOut(_ item: PhoneItem) -> Bool {
        if item.isEditedRender { editsBlocked = true; return false }
        storedHangs += 1
        return storedHangs >= 2
    }
}
