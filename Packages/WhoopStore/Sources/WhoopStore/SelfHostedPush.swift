import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// Apple client for the Experimental self-hosted push (docs/PUSH_PROTOCOL.md, issue #1314).
//
// Scope of this client: protocol 1.0, the four mutable replace-window streams (dailyMetric,
// sleepSession, workout, journal) and two append streams (hrSample, rrInterval). The other six
// append streams (raw waveforms, events, battery) are not compiled in, so the effective registry is
// the intersection of the receiver's list and these six. That is the rule the protocol already states
// for any client. Wire format, keys, windows, cursors and acknowledgement checks follow the document;
// this file is pure Foundation so `swift test` covers it with no app.
//
// Known difference from the Kotlin client: a Double is printed with Swift's shortest round-trip
// form, and Kotlin uses `Double.toString`. Both are valid JSON for the same value, but the decoded
// bytes (and therefore `batchId`) are not byte-identical across the two platforms. A batch ID only
// has to be stable across one sender's own retries, so a receiver sees no difference.

/// One JSON value of a record. Only the kinds the v1 registry can carry.
public enum PushValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
}

/// One `{"type":"record","key":…,"data":…}` line before encoding.
public struct PushRecord: Equatable, Sendable {
    public var key: [String: PushValue]
    public var data: [String: PushValue]
    public init(key: [String: PushValue], data: [String: PushValue]) {
        self.key = key
        self.data = data
    }
}

/// The fixed v1 mutable streams. Column lists are the registry in PUSH_PROTOCOL.md, in order.
public enum PushStream: String, CaseIterable, Sendable {
    case dailyMetric, sleepSession, workout, journal

    public enum Selector: String, Sendable { case day, startTs }

    public var keyColumns: [String] {
        switch self {
        case .dailyMetric: return ["day"]
        case .sleepSession: return ["startTs"]
        case .workout: return ["startTs", "sport"]
        case .journal: return ["day", "question"]
        }
    }

    public var dataColumns: [String] {
        switch self {
        case .dailyMetric:
            return ["totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances",
                    "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct",
                    "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir"]
        case .sleepSession:
            return ["endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON", "userEdited",
                    "startTsAdjusted", "motionJSON", "sleepStateJSON", "stagingSparse"]
        case .workout:
            return ["endTs", "source", "durationS", "energyKcal", "avgHr", "maxHr", "strain",
                    "distanceM", "zonesJSON", "notes", "routePolyline", "steps"]
        case .journal:
            return ["answeredYes", "notes", "numericValue"]
        }
    }

    /// SQLite stores these as 0/1 integers; the wire carries JSON booleans.
    public var booleanColumns: Set<String> {
        switch self {
        case .sleepSession: return ["userEdited", "stagingSparse"]
        case .journal: return ["answeredYes"]
        case .dailyMetric, .workout: return []
        }
    }

    public var selector: Selector {
        switch self {
        case .dailyMetric, .journal: return .day
        case .sleepSession, .workout: return .startTs
        }
    }
}

/// The append streams this client compiles in. Column lists are the registry in PUSH_PROTOCOL.md, in order.
/// Every column of both is an integer (the RR metadata is nullable).
public enum PushAppendStream: String, CaseIterable, Sendable {
    case hrSample, rrInterval

    public var keyColumns: [String] {
        switch self {
        case .hrSample: return ["ts"]
        case .rrInterval: return ["ts", "rrMs", "seq"]
        }
    }

    public var dataColumns: [String] {
        switch self {
        case .hrSample: return ["bpm"]
        case .rrInterval: return ["ord", "srcChannel", "tsSuspect"]
        }
    }

    /// Data columns that may be JSON null.
    var nullableColumns: Set<String> {
        switch self {
        case .hrSample: return []
        case .rrInterval: return ["ord", "srcChannel", "tsSuspect"]
        }
    }
}

/// An append highwater: the insertion position (SQLite rowid) of the last accepted row, and the
/// fingerprint of that row's natural key, so a rewritten database is noticed before the cursor is used.
public struct PushCursor: Codable, Equatable, Sendable {
    public let rowId: Int64
    public let keySha256: String
    public init(rowId: Int64, keySha256: String) {
        self.rowId = rowId
        self.keySha256 = keySha256
    }
}

/// One local row of an append stream, with its insertion position.
public struct PushAppendRow: Equatable, Sendable {
    public let rowId: Int64
    public let record: PushRecord
    public init(rowId: Int64, record: PushRecord) {
        self.rowId = rowId
        self.record = record
    }
}

/// One bounded append request.
public struct PushAppendBatch: Equatable, Sendable {
    public let batchId: String
    public let stream: PushAppendStream
    public let deviceId: String
    public let recordCount: Int
    public let startCursor: PushCursor?
    public let endCursor: PushCursor
    public let body: Data
}

/// A half-open window of whole local days: `fromDay` … `toDay` inclusive as dates, and the
/// matching local-midnight Unix bounds for the `startTs` streams.
public struct PushWindow: Equatable, Sendable {
    public let fromDay: String
    public let toDay: String
    public let endExclusiveDay: String
    public let startTsInclusive: Int64
    public let endTsExclusive: Int64

    /// The days `from` … `to` (inclusive) in `calendar`'s time zone.
    public static func days(from: Date, to: Date, calendar: Calendar) -> PushWindow {
        let first = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to)
        let next = calendar.date(byAdding: .day, value: 1, to: last)!
        return PushWindow(fromDay: PushDay.string(first, calendar), toDay: PushDay.string(last, calendar),
                          endExclusiveDay: PushDay.string(next, calendar),
                          startTsInclusive: Int64(first.timeIntervalSince1970),
                          endTsExclusive: Int64(next.timeIntervalSince1970))
    }

    func boundsJSON(_ selector: PushStream.Selector) -> [String: Any] {
        switch selector {
        case .day:
            return ["selector": "day", "startInclusive": fromDay, "endExclusive": endExclusiveDay]
        case .startTs:
            return ["selector": "startTs", "startInclusive": startTsInclusive, "endExclusive": endTsExclusive]
        }
    }
}

/// `YYYY-MM-DD` in a given calendar, the format of every `day` key.
public enum PushDay {
    public static func string(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

/// One bounded request of a replacement.
public struct PushBatch: Equatable, Sendable {
    public let batchId: String
    public let stream: PushStream
    public let deviceId: String
    public let replacementId: String
    public let part: Int
    public let parts: Int
    public let recordCount: Int
    public let body: Data
}

public struct PushProtocolError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum PushProtocol {
    public static let version = "1.0"
    public static let maxRecords = 5_000
    public static let maxBodyBytes = 4 * 1024 * 1024
    public static let maxResponseBytes = 16 * 1024
    /// Client memory bound for one replacement, as on Android: fail visibly, never truncate.
    public static let maxSnapshotRecords = 1_000
    public static let maxSnapshotBytes = 2 * 1024 * 1024
    static let forbiddenResponseMembers: Set<String> = ["command", "commands", "endpoint", "url",
                                                         "cadence", "schema", "fields"]
    static let placeholderUUID = "00000000-0000-0000-0000-000000000000"

    /// Every bounded part of one authoritative replacement. An empty window gives one empty part.
    public static func replacementBatches(stream: PushStream, sourceId: String, deviceId: String,
                                          window: PushWindow, records: [PushRecord]) throws -> [PushBatch] {
        guard UUID(uuidString: sourceId)?.uuidString.lowercased() == sourceId else {
            throw PushProtocolError("sourceId must be a lowercase canonical UUID")
        }
        let sorted = try records.map { try validated(stream, $0) }
            .sorted { compareKeys(stream, $0.key, $1.key) }
        for (a, b) in zip(sorted, sorted.dropFirst()) where !compareKeys(stream, a.key, b.key) {
            throw PushProtocolError("\(stream.rawValue) replacement contains a duplicate key")
        }
        let lines = sorted.map(recordLine)
        let bounds = window.boundsJSON(stream.selector)
        let replacementId = stableUUID(["deviceId": deviceId, "delivery": "replace_window",
                                        "protocolVersion": version, "sourceId": sourceId,
                                        "stream": stream.rawValue, "window": bounds], lines)

        func header(part: Int, parts: Int, count: Int, batchId: String) -> [String: Any] {
            var windowJSON = bounds
            windowJSON["replacementId"] = replacementId
            windowJSON["part"] = part
            windowJSON["parts"] = parts
            return ["type": "batch", "protocolVersion": version, "batchId": batchId, "sourceId": sourceId,
                    "deviceId": deviceId, "stream": stream.rawValue, "delivery": "replace_window",
                    "recordCount": count, "startCursor": NSNull(), "endCursor": NSNull(), "window": windowJSON]
        }
        // The largest header this replacement can have: used to size the parts conservatively.
        let headerRoom = canonicalLine(header(part: Int.max, parts: Int.max, count: maxRecords,
                                              batchId: placeholderUUID)).count
        var chunks: [[Data]] = []
        var current: [Data] = []
        var currentBytes = 0
        for line in lines {
            if headerRoom + line.count > maxBodyBytes {
                throw PushProtocolError("one \(stream.rawValue) record exceeds the 4 MiB batch limit")
            }
            if current.count + 1 > maxRecords || headerRoom + currentBytes + line.count > maxBodyBytes {
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            current.append(line)
            currentBytes += line.count
        }
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }

        return chunks.enumerated().map { index, partLines in
            let part = index + 1
            var identity = header(part: part, parts: chunks.count, count: partLines.count, batchId: "")
            identity.removeValue(forKey: "batchId")
            let batchId = stableUUID(identity, partLines)
            var body = canonicalLine(header(part: part, parts: chunks.count, count: partLines.count, batchId: batchId))
            partLines.forEach { body.append($0) }
            return PushBatch(batchId: batchId, stream: stream, deviceId: deviceId, replacementId: replacementId,
                             part: part, parts: chunks.count, recordCount: partLines.count, body: body)
        }
    }

    /// Local per-day content identity. Progress metadata only; never sent.
    public static func snapshotHash(stream: PushStream, records: [PushRecord]) throws -> String {
        let lines = try records.map { recordLine(try validated(stream, $0)) }
            .sorted { $0.lexicographicallyPrecedes($1) }
        var input = Data("noop-push-day-hash\n\(version)\n\(stream.rawValue)\n".utf8)
        lines.forEach { input.append($0) }
        return SHA256Digest.hex(input)
    }

    /// The encoded size of one record line, for the client memory bound.
    public static func encodedSize(stream: PushStream, record: PushRecord) throws -> Int {
        recordLine(try validated(stream, record)).count
    }

    // MARK: Append delivery

    /// The cursor fingerprint: SHA-256 of `stream` LF `deviceId` LF the compact natural-key object,
    /// with its members in registry order (not sorted).
    public static func cursorKeySha256(stream: PushAppendStream, deviceId: String, key: [String: PushValue]) -> String {
        var text = "{"
        for (index, column) in stream.keyColumns.enumerated() {
            if index > 0 { text += "," }
            appendQuoted(column, to: &text)
            text += ":"
            appendCanonical(json(key[column] ?? .null), to: &text)
        }
        text += "}"
        return SHA256Digest.hex(Data("\(stream.rawValue)\n\(deviceId)\n\(text)".utf8))
    }

    /// The bounded append requests for `rows` (in insertion order, all after `startCursor`).
    /// Each request starts where the one before it ends. No rows gives no request.
    public static func appendBatches(stream: PushAppendStream, sourceId: String, deviceId: String,
                                     startCursor: PushCursor?, rows: [PushAppendRow]) throws -> [PushAppendBatch] {
        guard UUID(uuidString: sourceId)?.uuidString.lowercased() == sourceId else {
            throw PushProtocolError("sourceId must be a lowercase canonical UUID")
        }
        var previous = startCursor?.rowId ?? Int64.min
        for row in rows {
            guard row.rowId > previous else { throw PushProtocolError("\(stream.rawValue) rows are not in insertion order") }
            previous = row.rowId
            try validatedAppend(stream, row.record)
        }
        func cursorJSON(_ cursor: PushCursor?) -> Any {
            guard let cursor else { return NSNull() }
            return ["rowId": cursor.rowId, "keySha256": cursor.keySha256]
        }
        func header(count: Int, start: PushCursor?, end: PushCursor, batchId: String) -> [String: Any] {
            ["type": "batch", "protocolVersion": version, "batchId": batchId, "sourceId": sourceId, "deviceId": deviceId,
             "stream": stream.rawValue, "delivery": "append", "recordCount": count,
             "startCursor": cursorJSON(start), "endCursor": cursorJSON(end)]
        }
        let widest = PushCursor(rowId: Int64.max, keySha256: String(repeating: "f", count: 64))
        let headerRoom = canonicalLine(header(count: maxRecords, start: widest, end: widest, batchId: placeholderUUID)).count

        var out: [PushAppendBatch] = []
        var start = startCursor
        var index = 0
        while index < rows.count {
            var lines: [Data] = []
            var bytes = headerRoom
            var end = index
            while end < rows.count && lines.count < maxRecords {
                let line = recordLine(rows[end].record)
                if headerRoom + line.count > maxBodyBytes {
                    throw PushProtocolError("one \(stream.rawValue) record exceeds the 4 MiB batch limit")
                }
                if bytes + line.count > maxBodyBytes { break }
                lines.append(line)
                bytes += line.count
                end += 1
            }
            let last = rows[end - 1]
            let endCursor = PushCursor(rowId: last.rowId,
                                       keySha256: cursorKeySha256(stream: stream, deviceId: deviceId, key: last.record.key))
            var identity = header(count: lines.count, start: start, end: endCursor, batchId: "")
            identity.removeValue(forKey: "batchId")
            let batchId = stableUUID(identity, lines)
            var body = canonicalLine(header(count: lines.count, start: start, end: endCursor, batchId: batchId))
            lines.forEach { body.append($0) }
            out.append(PushAppendBatch(batchId: batchId, stream: stream, deviceId: deviceId, recordCount: lines.count,
                                       startCursor: start, endCursor: endCursor, body: body))
            start = endCursor
            index = end
        }
        return out
    }

    @discardableResult
    static func validatedAppend(_ stream: PushAppendStream, _ record: PushRecord) throws -> PushRecord {
        guard Set(record.key.keys) == Set(stream.keyColumns), record.key.count == stream.keyColumns.count,
              Set(record.data.keys) == Set(stream.dataColumns), record.data.count == stream.dataColumns.count else {
            throw PushProtocolError("\(stream.rawValue) record does not match the registry")
        }
        for column in stream.keyColumns {
            guard case .int = record.key[column]! else { throw PushProtocolError("\(stream.rawValue).\(column) is not an integer") }
        }
        for column in stream.dataColumns {
            switch record.data[column]! {
            case .int: continue
            case .null where stream.nullableColumns.contains(column): continue
            default: throw PushProtocolError("\(stream.rawValue).\(column) is not an integer")
            }
        }
        return record
    }

    // MARK: Encoding

    static func validated(_ stream: PushStream, _ record: PushRecord) throws -> PushRecord {
        guard Set(record.key.keys) == Set(stream.keyColumns), record.key.count == stream.keyColumns.count else {
            throw PushProtocolError("\(stream.rawValue) key does not match the registry")
        }
        guard Set(record.data.keys) == Set(stream.dataColumns), record.data.count == stream.dataColumns.count else {
            throw PushProtocolError("\(stream.rawValue) data does not match the registry")
        }
        for value in record.key.values where value == .null {
            throw PushProtocolError("\(stream.rawValue) key has a null member")
        }
        for case .double(let d) in Array(record.key.values) + Array(record.data.values) where !d.isFinite {
            throw PushProtocolError("\(stream.rawValue) has a number that is not finite")
        }
        return record
    }

    /// Natural-key order: integers numerically, text by unsigned UTF-8 bytes (SQLite BINARY).
    /// Returns true when `a` sorts strictly before `b`.
    static func compareKeys(_ stream: PushStream, _ a: [String: PushValue], _ b: [String: PushValue]) -> Bool {
        for column in stream.keyColumns {
            switch (a[column], b[column]) {
            case let (.int(x)?, .int(y)?) where x != y: return x < y
            case let (.string(x)?, .string(y)?) where x != y:
                return Array(x.utf8).lexicographicallyPrecedes(Array(y.utf8))
            default: continue
            }
        }
        return false
    }

    static func recordLine(_ record: PushRecord) -> Data {
        canonicalLine(["type": "record", "key": record.key.mapValues(json), "data": record.data.mapValues(json)])
    }

    static func json(_ value: PushValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return JSONBool(b)
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        }
    }

    /// Booleans travel as a wrapper so `NSNumber` bridging cannot turn `true` into `1`.
    struct JSONBool { let value: Bool; init(_ value: Bool) { self.value = value } }

    static func canonicalLine(_ object: [String: Any]) -> Data {
        var text = ""
        appendCanonical(object, to: &text)
        text.append("\n")
        return Data(text.utf8)
    }

    /// Compact JSON with object members sorted by key. Deterministic for one platform.
    static func appendCanonical(_ value: Any, to out: inout String) {
        switch value {
        case is NSNull: out += "null"
        case let b as JSONBool: out += b.value ? "true" : "false"
        case let s as String: appendQuoted(s, to: &out)
        case let i as Int: out += String(i)
        case let i as Int64: out += String(i)
        case let d as Double: out += canonicalDouble(d)
        case let object as [String: Any]:
            out += "{"
            for (index, key) in object.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                appendQuoted(key, to: &out)
                out += ":"
                appendCanonical(object[key]!, to: &out)
            }
            out += "}"
        default:
            preconditionFailure("unsupported JSON value \(type(of: value))")
        }
    }

    /// Swift's shortest round-trip text, which is already valid JSON for a finite value
    /// ("61.0", "0.1", "1e-05"). Callers reject non-finite values before this point.
    static func canonicalDouble(_ d: Double) -> String { "\(d)" }

    static func appendQuoted(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
    }

    /// A name-based v5-style UUID over the identity and the exact record lines.
    static func stableUUID(_ identity: [String: Any], _ lines: [Data]) -> String {
        var input = canonicalLine(identity)
        lines.forEach { input.append($0) }
        var bytes = Array(SHA256Digest.hash(input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let p = Array(hex)
        return [p[0..<8], p[8..<12], p[12..<16], p[16..<20], p[20..<32]].map { String($0) }.joined(separator: "-")
    }
}

// MARK: Receiver responses

/// The authenticated capabilities document (`GET`).
public struct PushCapabilities: Equatable, Sendable {
    public let protocolVersion: String
    public let receiverStateId: String
    public let streams: Set<String>

    public static func parse(_ data: Data) throws -> PushCapabilities {
        guard data.count <= PushProtocol.maxResponseBytes else { throw PushProtocolError("capabilities exceed 16 KiB") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PushProtocolError("capabilities are not a JSON object")
        }
        guard object["type"] as? String == "capabilities" else { throw PushProtocolError("capabilities.type is wrong") }
        guard let version = object["protocolVersion"] as? String, version == PushProtocol.version else {
            throw PushProtocolError("the receiver did not select protocol \(PushProtocol.version)")
        }
        guard let state = object["receiverStateId"] as? String,
              UUID(uuidString: state)?.uuidString.lowercased() == state else {
            throw PushProtocolError("capabilities.receiverStateId is not a lowercase canonical UUID")
        }
        guard let names = object["streams"] as? [String] else { throw PushProtocolError("capabilities.streams is missing") }
        let registry: Set<String> = ["hrSample", "rrInterval", "event", "battery", "spo2Sample", "skinTempSample",
                                     "respSample", "gravitySample", "dailyMetric", "sleepSession", "workout", "journal"]
        guard Set(names).count == names.count, Set(names).isSubset(of: registry) else {
            throw PushProtocolError("capabilities.streams has a duplicate or unknown name")
        }
        return PushCapabilities(protocolVersion: version, receiverStateId: state, streams: Set(names))
    }
}

/// The acknowledgement of one batch. Valid only when every member matches the request exactly.
public enum PushAck {
    public static func matches(_ data: Data, batch: PushBatch) -> Bool {
        guard data.count <= PushProtocol.maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard Set(object.keys).isDisjoint(with: PushProtocol.forbiddenResponseMembers) else { return false }
        guard object["protocolVersion"] as? String == PushProtocol.version,
              object["batchId"] as? String == batch.batchId,
              object["stream"] as? String == batch.stream.rawValue,
              object["deviceId"] as? String == batch.deviceId,
              object["status"] as? String == "accepted",
              object.keys.contains("endCursor"), object["endCursor"] is NSNull else { return false }
        // JSONSerialization gives a JSON boolean as an NSNumber of type "c"; `true` is not the integer 1.
        guard let rows = object["acceptedRows"] as? NSNumber, String(cString: rows.objCType) != "c",
              rows.doubleValue == Double(batch.recordCount) else { return false }
        return true
    }

    /// The acknowledgement of one append batch: as `matches`, and `endCursor` must be the request's.
    public static func matches(_ data: Data, appendBatch batch: PushAppendBatch) -> Bool {
        guard data.count <= PushProtocol.maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard Set(object.keys).isDisjoint(with: PushProtocol.forbiddenResponseMembers) else { return false }
        guard object["protocolVersion"] as? String == PushProtocol.version,
              object["batchId"] as? String == batch.batchId,
              object["stream"] as? String == batch.stream.rawValue,
              object["deviceId"] as? String == batch.deviceId,
              object["status"] as? String == "accepted",
              let cursor = object["endCursor"] as? [String: Any], cursor.count == 2,
              let rowId = cursor["rowId"] as? NSNumber, String(cString: rowId.objCType) != "c",
              rowId.int64Value == batch.endCursor.rowId, rowId.doubleValue == Double(batch.endCursor.rowId),
              cursor["keySha256"] as? String == batch.endCursor.keySha256 else { return false }
        guard let rows = object["acceptedRows"] as? NSNumber, String(cString: rows.objCType) != "c",
              rows.doubleValue == Double(batch.recordCount) else { return false }
        return true
    }

    /// The validated `code` of an error body, or nil.
    public static func errorCode(_ data: Data) -> String? {
        guard data.count <= PushProtocol.maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "error", let code = object["code"] as? String,
              code.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil else { return nil }
        return code
    }
}

// MARK: Endpoint rule

public enum PushEndpointPolicy {
    /// HTTPS anywhere. Plain HTTP only to a numeric loopback, RFC 1918, link-local or IPv6 ULA
    /// address, never to a host name (that closes the DNS-rebinding gap). No user info, no fragment.
    public static func validate(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        if scheme == "https" { return url }
        guard scheme == "http" else { return nil }
        return isPrivateNumeric(host) ? url : nil
    }

    static func isPrivateNumeric(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            let octets = parts.compactMap { part -> Int? in
                guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let v = Int(part), v <= 255 else { return nil }
                return v
            }
            guard octets.count == 4 else { return false }
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, let b) where (16...31).contains(b): return true
            default: return false
            }
        }
        let v6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard v6.contains(":"), v6.allSatisfy({ $0.isHexDigit || $0 == ":" }) else { return false }
        return v6 == "::1" || v6.hasPrefix("fc") || v6.hasPrefix("fd") || v6.hasPrefix("fe8")
            || v6.hasPrefix("fe9") || v6.hasPrefix("fea") || v6.hasPrefix("feb")
    }

    /// The endpoint text that scopes progress: lower-case scheme and host, no default port.
    public static func normalized(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? url.absoluteString
    }
}

// MARK: SHA-256

/// FIPS 180-4 SHA-256. CryptoKit where it exists (fast; the append streams hash about 0.5 MB for each
/// request), and plain Swift elsewhere, so this package keeps building where CryptoKit is absent.
public enum SHA256Digest {
    public static func hex(_ data: Data) -> String { hash(data).map { String(format: "%02x", $0) }.joined() }

    public static func hash(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(CryptoKit.SHA256.hash(data: data))
        #else
        return portableHash(data)
        #endif
    }

    static func portableHash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.flatMap { v in [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) } }
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
}
