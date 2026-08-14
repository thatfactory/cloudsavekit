import Foundation
import Testing

@testable import CloudSaveKit

@Suite("Cloud save asynchronous lock")
struct CloudSaveAsyncLockTests {
    @Test("Serializes overlapping asynchronous operations")
    func serializesOperations() async {
        let lock = CloudSaveAsyncLock()
        let probe = CriticalSectionProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await lock.withLock {
                        await probe.enter()
                        await Task.yield()
                        await probe.leave()
                    }
                }
            }
        }

        let result = await probe.result()
        #expect(result.entryCount == 50)
        #expect(result.maximumConcurrentCount == 1)
    }
}

// MARK: - CriticalSectionProbe

extension CloudSaveAsyncLockTests {
    /// Records how many test operations overlap inside one critical section.
    private actor CriticalSectionProbe {
        private var activeCount = 0
        private var entryCount = 0
        private var maximumConcurrentCount = 0

        /// Records one operation entering the critical section.
        func enter() {
            activeCount += 1
            entryCount += 1
            maximumConcurrentCount = max(
                maximumConcurrentCount,
                activeCount
            )
        }

        /// Records one operation leaving the critical section.
        func leave() {
            activeCount -= 1
        }

        /// Returns the completed concurrency measurements.
        func result() -> (
            entryCount: Int,
            maximumConcurrentCount: Int
        ) {
            (
                entryCount: entryCount,
                maximumConcurrentCount: maximumConcurrentCount
            )
        }
    }
}
