import Foundation
import Core

func timeoutTests() async {
    // Answers in time → value.
    let v = try? await Timeout.callback(seconds: 1) { (done: @escaping @Sendable (Result<Int, Error>) -> Void) in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done(.success(7)) }
    }
    check(v == 7, "answer within the limit is returned")

    // Never answers → throws TimedOut quickly.
    let start = Date()
    await checkThrowsAsync("no answer throws") {
        _ = try await Timeout.callback(seconds: 0.2) { (_: @escaping @Sendable (Result<Int, Error>) -> Void) in }
    }
    check(Date().timeIntervalSince(start) < 1.5, "gives up near the limit")

    // Late answer after the timeout must not crash (resumed only once).
    await checkThrowsAsync("late answer ignored") {
        _ = try await Timeout.callback(seconds: 0.1) { (done: @escaping @Sendable (Result<Int, Error>) -> Void) in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done(.success(1)) }
        }
    }
    try? await Task.sleep(nanoseconds: 400_000_000)
    check(true, "survived a late answer")

    // Double answer must not crash.
    let twice = try? await Timeout.callback(seconds: 1) { (done: @escaping @Sendable (Result<Int, Error>) -> Void) in
        done(.success(1)); done(.success(2))
    }
    check(twice == 1, "first answer wins")
}
