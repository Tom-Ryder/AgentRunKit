import Foundation

/// One chunk's failure within a batch synthesis: its identity and the transport error that ended it.
public struct TTSChunkFailure: Sendable, Equatable {
    public let chunk: TTSChunk
    public let encoding: TTSAudioEncoding
    public let error: TransportError

    public init(chunk: TTSChunk, encoding: TTSAudioEncoding, error: TransportError) {
        self.chunk = chunk
        self.encoding = encoding
        self.error = error
    }

    public var index: Int {
        chunk.index
    }

    public var total: Int {
        chunk.total
    }

    public var text: String {
        chunk.text
    }

    public var sourceRange: Range<Int> {
        chunk.sourceRange
    }
}

/// The outcome of a batch synthesis: the segments that completed and the chunks that failed, preserved past a failure.
///
/// For a guide on audio workflows, see <doc:MultimodalAndAudio>.
public struct TTSBatchResult: Sendable, Equatable {
    /// The number of chunks in the full plan this result belongs to, even when only a subset was attempted.
    public let total: Int
    /// The completed segments, in ascending chunk-index order.
    public let completedSegments: [TTSSegment]
    /// The failed chunks, in ascending chunk-index order.
    public let failures: [TTSChunkFailure]

    public init(total: Int, completedSegments: [TTSSegment], failures: [TTSChunkFailure]) {
        precondition(total >= 1, "total must be at least 1")
        let completed = completedSegments.sorted { $0.index < $1.index }
        let failed = failures.sorted { $0.index < $1.index }
        let indices = completed.map(\.index) + failed.map(\.index)
        precondition(indices.allSatisfy { (0 ..< total).contains($0) }, "every covered index must be within 0..<total")
        precondition(completed.allSatisfy { $0.total == total }, "every segment must share the batch total")
        precondition(failed.allSatisfy { $0.total == total }, "every failure must share the batch total")
        precondition(Set(indices).count == indices.count, "each index may appear at most once")
        self.total = total
        self.completedSegments = completed
        self.failures = failed
    }

    public var completedIndices: [Int] {
        completedSegments.map(\.index)
    }

    public var failedIndices: [Int] {
        failures.map(\.index)
    }

    /// The chunks that failed, ready to pass back to ``TTSClient/generate(chunks:voice:options:)`` for a retry.
    public var failedChunks: [TTSChunk] {
        failures.map(\.chunk)
    }

    /// The plan indices this result did not attempt, in ascending order; non-empty only for a subset retry.
    public var missingIndices: [Int] {
        let attempted = Set(completedIndices).union(failedIndices)
        return (0 ..< total).filter { !attempted.contains($0) }
    }

    /// Whether every chunk in the full plan succeeded, so ``completedSegments`` is ready to assemble.
    public var isComplete: Bool {
        failures.isEmpty && missingIndices.isEmpty
    }

    /// Folds a subset retry into this result, replacing failed or missing indices with the retry's outcomes.
    ///
    /// Throws ``TTSError/invalidConfiguration(_:)`` if totals differ or a retry overwrites a completed chunk.
    public func merging(_ retry: TTSBatchResult) throws -> TTSBatchResult {
        guard total == retry.total else {
            throw TTSError.invalidConfiguration("merged batches must share the same total")
        }
        var completedByIndex: [Int: TTSSegment] = [:]
        var failedByIndex: [Int: TTSChunkFailure] = [:]
        for segment in completedSegments {
            completedByIndex[segment.index] = segment
        }
        for failure in failures {
            failedByIndex[failure.index] = failure
        }
        for segment in retry.completedSegments {
            guard completedByIndex[segment.index] == nil else {
                throw TTSError.invalidConfiguration("retry cannot replace a completed chunk at index \(segment.index)")
            }
            if let failed = failedByIndex[segment.index], failed.chunk != segment.chunk {
                throw TTSError.invalidConfiguration("retry chunk \(segment.index) does not match the failed chunk")
            }
            failedByIndex[segment.index] = nil
            completedByIndex[segment.index] = segment
        }
        for failure in retry.failures {
            guard completedByIndex[failure.index] == nil else {
                throw TTSError.invalidConfiguration("retry cannot fail a completed chunk at index \(failure.index)")
            }
            if let failed = failedByIndex[failure.index], failed.chunk != failure.chunk {
                throw TTSError.invalidConfiguration("retry chunk \(failure.index) does not match the failed chunk")
            }
            failedByIndex[failure.index] = failure
        }
        return TTSBatchResult(
            total: total,
            completedSegments: Array(completedByIndex.values),
            failures: Array(failedByIndex.values)
        )
    }
}
