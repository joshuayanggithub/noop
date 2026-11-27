import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP exchange. The app supplies a URLSession transport; tests supply a fake receiver.
public protocol PushTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

/// Local progress of the push: per destination namespace, the accepted hash of every local day of
/// every (stream, device), and every device scope already considered. Never transmitted.
public struct PushProgress: Codable, Equatable, Sendable {
    public struct Namespace: Codable, Equatable, Sendable {
        public var dayHashes: [String: [String: String]] = [:]   // "stream|device" → day → hash
        public var devices: [String: [String]] = [:]             // stream → device ids
        public var cursors: [String: PushCursor] = [:]           // "appendStream|device" → highwater

        public init() {}

        // Progress saved by a version without append streams has no "cursors": read it as empty.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            dayHashes = try container.decodeIfPresent([String: [String: String]].self, forKey: .dayHashes) ?? [:]
            devices = try container.decodeIfPresent([String: [String]].self, forKey: .devices) ?? [:]
            cursors = try container.decodeIfPresent([String: PushCursor].self, forKey: .cursors) ?? [:]
        }
    }
    public var namespaces: [String: Namespace] = [:]
    public init() {}
}

/// What one run did, in words the settings screen can show.
public struct PushRunReport: Equatable, Sendable {
    public var receiverStreams: [String] = []
    public var sent: [String] = []          // "dailyMetric my-whoop 2026-11-20…2026-11-25 (6 rows)"
    public var appendedRows = 0             // new hrSample and rrInterval rows accepted in this run
    public var appendPending = false        // an append stream stopped at the per-run cap; the next run continues
    public var unchanged = 0
    public var failures: [String] = []
    public var ok: Bool { failures.isEmpty }
}

/// One push attempt over the four mutable streams, then the two append streams (see SelfHostedPush.swift
/// for the scope).
/// Network or receiver failure never touches local data: progress moves only after an exact
/// acknowledgement of every part of a replacement.
public struct SelfHostedPushRunner: Sendable {
    public static let horizonDays = 14
    /// At most this many append requests for one (stream, device) in one run (2 million rows at most).
    /// A larger backlog continues on the next run, from the saved cursor.
    public static let maxAppendBatchesPerRun = 400
    public let endpoint: URL
    public let token: String
    public let sourceId: String
    public let transport: PushTransport
    public let calendar: Calendar

    public init(endpoint: URL, token: String, sourceId: String, transport: PushTransport, calendar: Calendar = .current) {
        self.endpoint = endpoint
        self.token = token
        self.sourceId = sourceId
        self.transport = transport
        self.calendar = calendar
    }

    /// The capabilities `GET` alone. It reads no health data.
    public func capabilities() async throws -> PushCapabilities {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(PushProtocol.version, forHTTPHeaderField: "NOOP-Push-Accept-Version")
        let (status, body) = try await transport.send(request)
        guard (200..<300).contains(status) else {
            throw PushProtocolError("capabilities: HTTP \(status)" + (PushAck.errorCode(body).map { " \($0)" } ?? ""))
        }
        return try PushCapabilities.parse(body)
    }

    public func run(store: WhoopStore, progress: inout PushProgress, now: Date = Date()) async -> PushRunReport {
        var report = PushRunReport()
        let capabilities: PushCapabilities
        do {
            capabilities = try await self.capabilities()
        } catch {
            report.failures.append("\(error)")
            return report
        }
        report.receiverStreams = capabilities.streams.sorted()
        let streams = PushStream.allCases.filter { capabilities.streams.contains($0.rawValue) }
        let appendStreams = PushAppendStream.allCases.filter { capabilities.streams.contains($0.rawValue) }
        if streams.isEmpty && appendStreams.isEmpty { return report }
        let namespaceKey = SHA256Digest.hex(Data([sourceId, PushEndpointPolicy.normalized(endpoint),
                                                  capabilities.protocolVersion, capabilities.receiverStateId]
            .joined(separator: "\n").utf8))
        var namespace = progress.namespaces[namespaceKey] ?? PushProgress.Namespace()

        let today = calendar.startOfDay(for: now)
        let dayDates = (0..<Self.horizonDays).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
        let dayNames = dayDates.map { PushDay.string($0, calendar) }
        let horizon = PushWindow.days(from: dayDates.first!, to: dayDates.last!, calendar: calendar)

        let liveDevices: [String]
        do {
            liveDevices = streams.isEmpty ? [] : try await store.pushDeviceIds(streams: streams)
        } catch {
            report.failures.append("device list: \(error)")
            return report
        }
        for stream in streams {
            let devices = Set(liveDevices).union(namespace.devices[stream.rawValue] ?? []).sorted()
            for device in devices {
                // A cancelled run (iOS ended the background time) stops between scopes; progress so far is kept.
                if Task.isCancelled {
                    report.failures.append("cancelled")
                    break
                }
                let scope = "\(stream.rawValue)|\(device)"
                do {
                    let records = try await store.pushRecords(stream: stream, deviceId: device, window: horizon)
                    var byDay: [String: [PushRecord]] = [:]
                    for record in records { byDay[dayName(of: record, stream), default: []].append(record) }
                    var current: [String: String] = [:]
                    for day in dayNames { current[day] = try PushProtocol.snapshotHash(stream: stream, records: byDay[day] ?? []) }
                    var stored = namespace.dayHashes[scope] ?? [:]
                    let changed = dayNames.indices.filter { stored[dayNames[$0]] != current[dayNames[$0]] }
                    guard let first = changed.first, let last = changed.last else {
                        report.unchanged += 1
                        continue
                    }
                    let window = PushWindow.days(from: dayDates[first], to: dayDates[last], calendar: calendar)
                    let inWindow = dayNames[first...last].flatMap { byDay[$0] ?? [] }
                    let batches = try PushProtocol.replacementBatches(stream: stream, sourceId: sourceId, deviceId: device,
                                                                      window: window, records: inWindow)
                    for batch in batches { try await post(batch) }
                    for day in dayNames[first...last] { stored[day] = current[day] }
                    stored = stored.filter { $0.key >= horizon.fromDay }
                    namespace.dayHashes[scope] = stored
                    var known = Set(namespace.devices[stream.rawValue] ?? [])
                    known.insert(device)
                    namespace.devices[stream.rawValue] = known.sorted()
                    progress.namespaces[namespaceKey] = namespace
                    report.sent.append("\(stream.rawValue) \(device) \(window.fromDay)…\(window.toDay) (\(inWindow.count) rows)")
                } catch {
                    report.failures.append("\(scope): \(error)")
                }
            }
        }
        // The append streams come after the day numbers, so a long backlog never delays them.
        for stream in appendStreams where !Task.isCancelled {
            await pushAppend(stream: stream, store: store, since: horizon.startTsInclusive, namespace: &namespace,
                             save: { progress.namespaces[namespaceKey] = $0 }, report: &report)
        }
        if namespace != PushProgress.Namespace() { progress.namespaces[namespaceKey] = namespace }
        return report
    }

    /// Sends the new rows of one append stream, device by device, from each saved cursor. A device with
    /// no cursor starts at the first row of the horizon. The cursor moves only after an exact
    /// acknowledgement, and it is saved after each request, so a stopped run loses no progress.
    func pushAppend(stream: PushAppendStream, store: WhoopStore, since: Int64, namespace: inout PushProgress.Namespace,
                    save: (PushProgress.Namespace) -> Void, report: inout PushRunReport) async {
        let devices: [String]
        do {
            devices = Set(try await store.pushAppendDeviceIds(stream: stream))
                .union(namespace.devices[stream.rawValue] ?? []).sorted()
        } catch {
            report.failures.append("\(stream.rawValue) device list: \(error)")
            return
        }
        for device in devices {
            if Task.isCancelled {
                report.failures.append("cancelled")
                return
            }
            let scope = "\(stream.rawValue)|\(device)"
            do {
                var cursor = namespace.cursors[scope]
                if let saved = cursor, !(try await store.pushAppendCursorIsValid(stream: stream, deviceId: device, cursor: saved)) {
                    cursor = nil
                    namespace.cursors[scope] = nil
                }
                var after: Int64
                if let cursor {
                    after = cursor.rowId
                } else if let floor = try await store.pushAppendFloor(stream: stream, deviceId: device, sinceTs: since) {
                    after = floor
                } else {
                    continue
                }
                var requests = 0, rows = 0
                while requests < Self.maxAppendBatchesPerRun {
                    if Task.isCancelled { break }
                    let page = try await store.pushAppendRows(stream: stream, deviceId: device, afterRowId: after,
                                                              limit: PushProtocol.maxRecords)
                    if page.isEmpty { break }
                    let batches = try PushProtocol.appendBatches(stream: stream, sourceId: sourceId, deviceId: device,
                                                                 startCursor: cursor, rows: page)
                    for batch in batches where requests < Self.maxAppendBatchesPerRun {
                        try await post(batch)
                        cursor = batch.endCursor
                        after = batch.endCursor.rowId
                        namespace.cursors[scope] = batch.endCursor
                        var known = Set(namespace.devices[stream.rawValue] ?? [])
                        if known.insert(device).inserted { namespace.devices[stream.rawValue] = known.sorted() }
                        save(namespace)
                        requests += 1
                        rows += batch.recordCount
                        report.appendedRows += batch.recordCount
                    }
                    if page.count < PushProtocol.maxRecords && after == page.last?.rowId { break }
                }
                if requests >= Self.maxAppendBatchesPerRun { report.appendPending = true }
                if rows > 0 { report.sent.append("\(stream.rawValue) \(device) (\(rows) new rows)") }
            } catch {
                report.failures.append("\(scope): \(error)")
            }
        }
    }

    func dayName(of record: PushRecord, _ stream: PushStream) -> String {
        switch stream.selector {
        case .day:
            if case .string(let day)? = record.key["day"] { return day }
            return ""
        case .startTs:
            if case .int(let ts)? = record.key["startTs"] {
                return PushDay.string(Date(timeIntervalSince1970: TimeInterval(ts)), calendar)
            }
            return ""
        }
    }

    func post(_ batch: PushBatch) async throws {
        let body = try await send(batch.body)
        guard PushAck.matches(body, batch: batch) else {
            throw PushProtocolError("the receiver's acknowledgement does not match the batch")
        }
    }

    func post(_ batch: PushAppendBatch) async throws {
        let body = try await send(batch.body)
        guard PushAck.matches(body, appendBatch: batch) else {
            throw PushProtocolError("the receiver's acknowledgement does not match the batch")
        }
    }

    /// One batch POST. Returns the response body of a 2xx response.
    func send(_ entity: Data) async throws -> Data {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-ndjson; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = entity
        let (status, body) = try await transport.send(request)
        guard (200..<300).contains(status) else {
            throw PushProtocolError("HTTP \(status)" + (PushAck.errorCode(body).map { " \($0)" } ?? ""))
        }
        return body
    }
}

/// URLSession transport. Redirects are never followed, so the bearer token never moves to another URL.
public final class URLSessionPushTransport: NSObject, PushTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session = URLSession(configuration: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        return configuration
    }(), delegate: self, delegateQueue: nil)

    public override init() { super.init() }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PushProtocolError("no HTTP response") }
        return (http.statusCode, data.prefix(PushProtocol.maxResponseBytes + 1))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
