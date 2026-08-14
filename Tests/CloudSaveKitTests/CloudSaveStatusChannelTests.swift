import Testing

@testable import CloudSaveKit

@Suite("Cloud save status channel")
struct CloudSaveStatusChannelTests {
    @Test("Starts with the idle status")
    func startsIdle() async {
        let channel = CloudSaveStatusChannel()
        channel.continuation.finish()
        var iterator = channel.stream.makeAsyncIterator()

        let status = await iterator.next()

        #expect(status == .idle)
    }

    @Test("Retains only the latest unconsumed status")
    func retainsLatestStatus() async {
        let channel = CloudSaveStatusChannel()
        channel.continuation.yield(.fetching)
        channel.continuation.yield(.sending)
        channel.continuation.finish()
        var iterator = channel.stream.makeAsyncIterator()

        let status = await iterator.next()
        let completion = await iterator.next()

        #expect(status == .sending)
        #expect(completion == nil)
    }
}
