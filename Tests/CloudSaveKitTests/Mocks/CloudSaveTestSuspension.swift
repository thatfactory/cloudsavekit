import Foundation

/// Holds deterministic asynchronous operations at a chosen lifecycle boundary without sleeps.
actor CloudSaveTestSuspension {
    private var arrivals = 0
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    /// Signals entry and waits until the test releases all current and future callers.
    func suspend() async {
        arrivals += 1
        let ready = observers.filter { $0.0 <= arrivals }
        observers.removeAll { $0.0 <= arrivals }
        for (_, continuation) in ready {
            continuation.resume()
        }
        guard !released else {
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Waits until the requested number of operations have reached this boundary.
    func waitUntilSuspended(count: Int = 1) async {
        guard arrivals < count else {
            return
        }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    /// Releases operations independently of task cancellation to exercise late completions.
    func resume() {
        released = true
        let continuations = waiting
        waiting.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
