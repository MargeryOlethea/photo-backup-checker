import Foundation

nonisolated(unsafe) private var failures: [String] = []
nonisolated(unsafe) private var total = 0

func check(_ cond: @autoclosure () throws -> Bool, _ name: String, file: String = #fileID, line: Int = #line) {
    total += 1
    let ok = (try? cond()) ?? false
    if !ok { failures.append("FAIL \(file):\(line) \(name)") }
}

func checkThrows(_ name: String, file: String = #fileID, line: Int = #line, _ body: () throws -> Void) {
    total += 1
    do { try body(); failures.append("FAIL \(file):\(line) \(name) (did not throw)") } catch {}
}

func checkThrowsAsync(_ name: String, file: String = #fileID, line: Int = #line, _ body: () async throws -> Void) async {
    total += 1
    do { try await body(); failures.append("FAIL \(file):\(line) \(name) (did not throw)") } catch {}
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("pbc-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func runChecks() -> Int32 {
    failures.forEach { print($0) }
    if failures.isEmpty { print("ALL CHECKS PASSED (\(total))"); return 0 }
    print("\(failures.count) of \(total) checks failed"); return 1
}
