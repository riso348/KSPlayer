//
//  URLSessionAVIOContext.swift
//  KSPlayer (RMDB fork)
//
//  HTTP(S) input for FFmpeg through URLSession instead of FFmpeg's own
//  network stack (KSOptions.urlSessionIO).
//
//  FFmpegKit's https runs on GnuTLS + nettle, whose AES is plain C: profiled
//  on Apple TV 4K (2026-11-09), the read thread of an 85 Mbit/s remux spent
//  96 % of its time in nettle_gcm_decrypt / _nettle_aes_encrypt, a whole
//  core at the 230 Mbit/s buffer refills — enough to drive the box into
//  thermal state "serious". URLSession decrypts with the CPU's AES
//  instructions.
//
//  Behaves like FFmpeg's http protocol with reconnect: one streaming Range
//  request from the read position, a fresh one on every seek outside what
//  is buffered, and resuming where it stopped when a connection drops.
//  Read-ahead is bounded (the task is suspended, TCP does the rest).
//

import FFmpegKit
import Foundation
import Libavformat

public final class URLSessionAVIOContext: AbstractAVIOContext {
    /// Bytes fetched ahead of the read position before the transfer pauses.
    private static let maxAhead = 32 * 1024 * 1024
    private static let resumeBelow = 16 * 1024 * 1024
    private static let readTimeout: TimeInterval = 30
    private static let maxRetries = 8

    private let originalURL: URL
    private let headers: [String: String]
    private let loader = Loader()
    private let session: URLSession
    private let condition = NSCondition()

    // Guarded by `condition`.
    /// Downloaded, not yet read; starts at `chunksStart`.
    private var chunks = [Data]()
    private var chunksBytes = 0
    private var chunksStart: Int64 = 0
    private var position: Int64 = 0
    private var total: Int64 = -1
    private var finished = false
    private var failure: Int32?
    private var closed = false
    private var task: URLSessionDataTask?
    /// Bumped per request, so callbacks of a cancelled one are ignored.
    private var generation = 0
    private var suspended = false
    private var retries = 0
    /// After redirects (e.g. /api/stream/… → CDN), used for later ranges.
    private var resolvedURL: URL?

    public init(url: URL, headers: [String: String] = [:]) {
        originalURL = url
        self.headers = headers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Self.readTimeout
        configuration.httpMaximumConnectionsPerHost = 2
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "ks.urlsession.avio"
        session = URLSession(configuration: configuration, delegate: loader, delegateQueue: queue)
        super.init(bufferSize: 256 * 1024)
        loader.owner = self
        condition.lock()
        start(at: 0)
        condition.unlock()
    }

    // MARK: - AbstractAVIOContext

    override public func read(buffer: UnsafePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        let destination = UnsafeMutablePointer(mutating: buffer)
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(Self.readTimeout)
        while chunksBytes == 0, !finished, failure == nil, !closed {
            if !condition.wait(until: deadline) {
                KSLog("[urlsession] read timed out at \(position)")
                return swift_AVERROR(ETIMEDOUT)
            }
        }
        if closed { return swift_AVERROR_EXIT }
        if chunksBytes == 0 {
            if let failure { return failure }
            return swift_AVERROR_EOF
        }
        var copied = 0
        while copied < Int(size), !chunks.isEmpty {
            let chunk = chunks[0]
            let count = min(Int(size) - copied, chunk.count)
            chunk.withUnsafeBytes { raw in
                (destination + copied).update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: count)
            }
            copied += count
            if count == chunk.count {
                chunks.removeFirst()
            } else {
                chunks[0] = chunk.subdata(in: count ..< chunk.count)
            }
        }
        chunksBytes -= copied
        chunksStart += Int64(copied)
        position += Int64(copied)
        if suspended, chunksBytes < Self.resumeBelow {
            suspended = false
            task?.resume()
        }
        return Int32(copied)
    }

    override public func seek(offset: Int64, whence: Int32) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        let target: Int64
        switch whence & ~AVSEEK_FORCE {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = position + offset
        case SEEK_END:
            guard total >= 0 else { return -1 }
            target = total + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        if target == position {
            return target
        }
        let bufferedEnd = chunksStart + Int64(chunksBytes)
        if target > position, target <= bufferedEnd {
            // Ahead inside what is buffered: skip.
            discard(Int(target - position))
            return target
        }
        // A short hop ahead of the download: cheaper to read on than to reconnect.
        if target > bufferedEnd, target - bufferedEnd < 2 * 1024 * 1024, !finished, failure == nil {
            discard(chunksBytes)
            let deadline = Date().addingTimeInterval(Self.readTimeout)
            while chunksStart + Int64(chunksBytes) < target, !finished, failure == nil, !closed {
                if suspended {
                    suspended = false
                    task?.resume()
                }
                if !condition.wait(until: deadline) { break }
            }
            if chunksStart + Int64(chunksBytes) >= target {
                discard(Int(target - position))
                return target
            }
        }
        start(at: target)
        return target
    }

    override public func fileSize() -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(Self.readTimeout)
        while total < 0, failure == nil, !finished, !closed {
            if !condition.wait(until: deadline) { break }
        }
        return total
    }

    override public func close() {
        condition.lock()
        closed = true
        generation += 1
        task?.cancel()
        task = nil
        chunks.removeAll()
        chunksBytes = 0
        condition.broadcast()
        condition.unlock()
        session.invalidateAndCancel()
    }

    // MARK: - Transfer (call with `condition` locked)

    private func discard(_ count: Int) {
        var left = count
        while left > 0, !chunks.isEmpty {
            let chunk = chunks[0]
            if chunk.count <= left {
                left -= chunk.count
                chunks.removeFirst()
            } else {
                chunks[0] = chunk.subdata(in: left ..< chunk.count)
                left = 0
            }
        }
        let dropped = count - left
        chunksBytes -= dropped
        chunksStart += Int64(dropped)
        position += Int64(dropped)
    }

    /// New request from `offset`, dropping the buffer (a seek).
    private func start(at offset: Int64, resolved: Bool = true) {
        chunks.removeAll()
        chunksBytes = 0
        chunksStart = offset
        position = offset
        request(from: offset, resolved: resolved)
    }

    /// New request continuing after what is buffered (a reconnect).
    private func request(from offset: Int64, resolved: Bool = true) {
        generation += 1
        task?.cancel()
        finished = false
        failure = nil
        suspended = false
        if total >= 0, offset >= total {
            finished = true
            condition.broadcast()
            return
        }
        var request = URLRequest(url: resolved ? (resolvedURL ?? originalURL) : originalURL)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        task.taskDescription = String(generation)
        self.task = task
        task.resume()
    }

    fileprivate func received(response: URLResponse, task: URLSessionDataTask) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard task.taskDescription == String(generation), let http = response as? HTTPURLResponse else { return false }
        guard http.statusCode == 206 || http.statusCode == 200 else {
            if resolvedURL != nil, [401, 403, 404, 410].contains(http.statusCode) {
                // The CDN link expired: go through the original URL again.
                resolvedURL = nil
                request(from: chunksStart + Int64(chunksBytes), resolved: false)
                return false
            }
            failure = swift_AVERROR(EIO)
            KSLog("[urlsession] HTTP \(http.statusCode)")
            condition.broadcast()
            return false
        }
        resolvedURL = http.url
        if http.statusCode == 200, chunksStart > 0 {
            // No range support: cannot seek.
            failure = swift_AVERROR(ESPIPE)
            condition.broadcast()
            return false
        }
        if let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/"), let size = Int64(range[range.index(after: slash)...]) {
            total = size
        } else if http.expectedContentLength > 0 {
            total = chunksStart + http.expectedContentLength
        }
        retries = 0
        condition.broadcast()
        return true
    }

    fileprivate func received(data: Data, task: URLSessionDataTask) {
        condition.lock()
        defer { condition.unlock() }
        guard task.taskDescription == String(generation) else { return }
        chunks.append(data)
        chunksBytes += data.count
        if chunksBytes > Self.maxAhead, !suspended {
            suspended = true
            task.suspend()
        }
        condition.broadcast()
    }

    fileprivate func completed(task: URLSessionTask, error: Error?) {
        condition.lock()
        defer { condition.unlock() }
        guard task.taskDescription == String(generation), !closed else { return }
        let end = chunksStart + Int64(chunksBytes)
        if total >= 0, end >= total {
            finished = true
        } else if retries < Self.maxRetries {
            // Dropped mid-file: carry on from where the data stopped.
            retries += 1
            KSLog("[urlsession] connection ended at \(end) (\(error?.localizedDescription ?? "no error")), retry \(retries)")
            let delay = min(Double(retries) * 0.5, 3)
            let gen = generation
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.condition.lock()
                defer { self.condition.unlock() }
                // A seek in the meantime started its own request.
                guard gen == self.generation, !self.closed else { return }
                self.request(from: self.chunksStart + Int64(self.chunksBytes))
            }
            return
        } else {
            failure = swift_AVERROR(EIO)
        }
        condition.broadcast()
    }

    private final class Loader: NSObject, URLSessionDataDelegate {
        weak var owner: URLSessionAVIOContext?

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let accept = owner?.received(response: response, task: dataTask) ?? false
            completionHandler(accept ? .allow : .cancel)
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.received(data: data, task: dataTask)
        }

        func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if (error as? URLError)?.code == .cancelled { return }
            owner?.completed(task: task, error: error)
        }
    }
}

extension KSOptions {
    /// "Key: value\r\n" pairs set with appendHeader.
    var httpHeaders: [String: String] {
        guard let raw = formatContextOptions["headers"] as? String else { return [:] }
        var out = [String: String]()
        for line in raw.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            out[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}
