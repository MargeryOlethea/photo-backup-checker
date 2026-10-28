import Foundation

public struct TimedOut: Error { public init() {} }

public enum Timeout {
    /// Waits for a callback-style answer, giving up after `seconds`, or at once when the task is cancelled (Stop).
    /// The first of answer/timeout/cancel wins; anything after that is ignored, so it can never resume twice.
    public static func callback<T: Sendable>(seconds: Double,
                                             _ start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let once = Once<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                guard once.set(cont) else { return }   // already stopped: never send the request
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { once.finish(.failure(TimedOut())) }
                guard !once.isDone else { return }   // stopped in between: still don't send it
                start { once.finish($0) }
            }
        } onCancel: { once.finish(.failure(CancellationError())) }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T, Error>?
        private var early: Result<T, Error>?   // cancelled before the wait began
        private var done = false
        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
        /// False when it already ended (cancelled before the wait began): the caller must not start anything.
        func set(_ c: CheckedContinuation<T, Error>) -> Bool {
            lock.lock()
            guard let early else { cont = c; lock.unlock(); return true }
            done = true; lock.unlock(); c.resume(with: early)
            return false
        }
        func finish(_ r: Result<T, Error>) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            guard let c = cont else { if early == nil { early = r }; lock.unlock(); return }
            done = true; cont = nil; lock.unlock(); c.resume(with: r)
        }
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
