@testable import AgentRunKit
import Foundation
import Testing

private func makeEvent(_ index: Int) -> StreamEvent {
    StreamEvent(kind: .delta("event-\(index)"))
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

struct StreamEventBufferTests {
    @Test
    func recordAssignsMonotonicCursors() async {
        let buffer = StreamEventBuffer(capacity: 8)
        var cursors: [UInt64] = []
        for index in 0 ..< 5 {
            await cursors.append(buffer.record(makeEvent(index)))
        }
        #expect(cursors == [0, 1, 2, 3, 4])
    }

    @Test
    func replayFromZeroYieldsAllRecorded() async throws {
        let buffer = StreamEventBuffer(capacity: 8)
        for index in 0 ..< 3 {
            await buffer.record(makeEvent(index))
        }
        let events = try await collect(buffer.replay(from: 0))
        #expect(events.count == 3)
        for index in 0 ..< 3 {
            if case let .delta(text) = events[index].kind {
                #expect(text == "event-\(index)")
            } else {
                Issue.record("Expected delta kind at index \(index)")
            }
        }
    }

    @Test
    func replayFromMidCursorYieldsTail() async throws {
        let buffer = StreamEventBuffer(capacity: 8)
        for index in 0 ..< 5 {
            await buffer.record(makeEvent(index))
        }
        let events = try await collect(buffer.replay(from: 2))
        #expect(events.count == 3)
        if case let .delta(text) = events.first?.kind {
            #expect(text == "event-2")
        } else {
            Issue.record("Expected first replayed event to be event-2")
        }
        if case let .delta(text) = events.last?.kind {
            #expect(text == "event-4")
        } else {
            Issue.record("Expected last replayed event to be event-4")
        }
    }

    @Test
    func replayFromCurrentCursorYieldsEmpty() async throws {
        let buffer = StreamEventBuffer(capacity: 8)
        for index in 0 ..< 3 {
            await buffer.record(makeEvent(index))
        }
        let events = try await collect(buffer.replay(from: 3))
        #expect(events.isEmpty)
    }

    @Test
    func replayFromFutureCursorThrowsCursorInFuture() async {
        let buffer = StreamEventBuffer(capacity: 8)
        for index in 0 ..< 2 {
            await buffer.record(makeEvent(index))
        }
        do {
            _ = try await collect(buffer.replay(from: 10))
            Issue.record("Expected BufferReplayError.cursorInFuture")
        } catch let BufferReplayError.cursorInFuture(currentCursor) {
            #expect(currentCursor == 2)
        } catch {
            Issue.record("Expected BufferReplayError.cursorInFuture, got \(error)")
        }
    }

    @Test
    func replayFromTrimmedCursorThrowsCursorTrimmed() async {
        let buffer = StreamEventBuffer(capacity: 4)
        for index in 0 ..< 10 {
            await buffer.record(makeEvent(index))
        }
        do {
            _ = try await collect(buffer.replay(from: 0))
            Issue.record("Expected BufferReplayError.cursorTrimmed")
        } catch let BufferReplayError.cursorTrimmed(oldestAvailable) {
            #expect(oldestAvailable == 6)
        } catch {
            Issue.record("Expected BufferReplayError.cursorTrimmed, got \(error)")
        }
    }

    @Test
    func capacityOverflowEvictsOldestEntries() async throws {
        let buffer = StreamEventBuffer(capacity: 3)
        for index in 0 ..< 5 {
            await buffer.record(makeEvent(index))
        }
        let events = try await collect(buffer.replay(from: 2))
        #expect(events.count == 3)
        let texts = events.compactMap { event -> String? in
            if case let .delta(text) = event.kind { return text }
            return nil
        }
        #expect(texts == ["event-2", "event-3", "event-4"])
    }

    @Test
    func clearResetsToEmpty() async throws {
        let buffer = StreamEventBuffer(capacity: 8)
        for index in 0 ..< 3 {
            await buffer.record(makeEvent(index))
        }
        await buffer.clear()
        let emptied = try await collect(buffer.replay(from: 0))
        #expect(emptied.isEmpty)
        let cursorAfterClear = await buffer.record(makeEvent(99))
        #expect(cursorAfterClear == 0)
        #expect(await buffer.cursor == 1)
    }

    @Test
    func concurrentRecordersPreserveCursorOrdering() async {
        let buffer = StreamEventBuffer(capacity: 256)
        let cursors = await withTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
            for index in 0 ..< 100 {
                group.addTask {
                    await buffer.record(makeEvent(index))
                }
            }
            var assigned: [UInt64] = []
            for await cursor in group {
                assigned.append(cursor)
            }
            return assigned
        }
        #expect(Set(cursors) == Set(UInt64(0) ..< UInt64(100)))
        #expect(await buffer.cursor == 100)
    }

    @Test
    func sustainedRecordCompletesWithinTotalBudget() async {
        let buffer = StreamEventBuffer(capacity: 1024)
        let clock = ContinuousClock()
        let iterations = 10000
        let start = clock.now
        for index in 0 ..< iterations {
            await buffer.record(makeEvent(index))
        }
        let elapsed = clock.now - start
        #expect(elapsed < .milliseconds(500))
    }

    @Test
    func replaySnapshotIsTakenAtCallTime() async throws {
        let buffer = StreamEventBuffer(capacity: 16)
        for index in 0 ..< 3 {
            await buffer.record(makeEvent(index))
        }
        let stream = await buffer.replay(from: 0)
        for index in 3 ..< 6 {
            await buffer.record(makeEvent(index))
        }
        let events = try await collect(stream)
        #expect(events.count == 3)
        let texts = events.compactMap { event -> String? in
            if case let .delta(text) = event.kind { return text }
            return nil
        }
        #expect(texts == ["event-0", "event-1", "event-2"])
    }
}
