import Foundation
import Synchronization

/// Streams one URL into a file, resuming from the file's current length with an HTTP `Range` request.
/// Bytes go straight to disk (never buffered whole in memory). Cancelling the calling task cancels the transfer
/// and leaves the partial file in place for a later resume.
struct FileTransfer: Sendable {
    let configuration: URLSessionConfiguration

    /// Downloads `url` into `destination`. `onBytes` receives the number of new bytes as they arrive.
    /// Returns the final file length.
    @discardableResult
    func run(_ url: URL, to destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: destination.path) { fm.createFile(atPath: destination.path, contents: nil) }
        let existing = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("LayX", forHTTPHeaderField: "User-Agent")
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let delegate = TransferDelegate(destination: destination, resumeOffset: existing, onBytes: onBytes)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                delegate.start(continuation: c)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// URLSession delegate for `FileTransfer`. Callbacks arrive on URLSession's serial delegate queue; all mutable
/// state is additionally guarded by a `Mutex`, which is what makes the type `Sendable`.
private final class TransferDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var handle: FileHandle?
        var failure: Error?
    }

    private let state = Mutex(State())
    private let destination: URL
    private let resumeOffset: Int64
    private let onBytes: @Sendable (Int64) -> Void

    init(destination: URL, resumeOffset: Int64, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.resumeOffset = resumeOffset
        self.onBytes = onBytes
    }

    func start(continuation: CheckedContinuation<Void, Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            let handle = try FileHandle(forWritingTo: destination)
            switch status {
            case 206:
                try handle.seekToEnd()
            case 200:
                // Server ignored the Range header (or there was none): start over.
                try handle.truncate(atOffset: 0)
                if resumeOffset > 0 { onBytes(-resumeOffset) }
            case 416:
                // Range not satisfiable: the partial file is already complete (verified by size/hash later).
                try handle.close()
                completionHandler(.cancel)
                finish(error: nil)
                return
            default:
                try handle.close()
                state.withLock { $0.failure = ModelStoreError.http(status: status) }
                completionHandler(.cancel)
                return
            }
            state.withLock { $0.handle = handle }
            completionHandler(.allow)
        } catch {
            state.withLock { $0.failure = error }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let wrote: Bool = state.withLock { s in
            guard let handle = s.handle else { return false }
            do {
                try handle.write(contentsOf: data)
                return true
            } catch {
                s.failure = error
                dataTask.cancel()
                return false
            }
        }
        if wrote { onBytes(Int64(data.count)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error)
    }

    private func finish(error: Error?) {
        let (continuation, failure): (CheckedContinuation<Void, Error>?, Error?) = state.withLock { s in
            try? s.handle?.synchronize()
            try? s.handle?.close()
            s.handle = nil
            let c = s.continuation
            s.continuation = nil
            return (c, s.failure)
        }
        guard let continuation else { return }
        if let failure {
            continuation.resume(throwing: failure)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: ModelStoreError.network(error.localizedDescription))
            }
        } else {
            continuation.resume()
        }
    }
}
