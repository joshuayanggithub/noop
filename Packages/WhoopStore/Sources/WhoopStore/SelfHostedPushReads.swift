import Foundation
import GRDB

// Snapshot reads for the self-hosted push (SelfHostedPush.swift). Explicit registry projections,
// never `SELECT *`: a registry column this platform's table does not have is sent as JSON null, and
// Apple-only columns (avgSdnn, skinTempC, sleepHrOnly, …) stay out of the wire format.
extension WhoopStore {

    /// Every device scope that has rows in one of `streams`, plus every registered device.
    public func pushDeviceIds(streams: [PushStream]) throws -> [String] {
        try dbWriter.read { db in
            var ids = Set(try String.fetchAll(db, sql: "SELECT id FROM device WHERE id <> ''"))
            for stream in streams {
                ids.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT deviceId FROM \(stream.rawValue) WHERE deviceId <> ''"))
            }
            return ids.sorted()
        }
    }

    /// The rows of one device in `window`, sorted by natural key, with the registry columns only.
    /// Fails (never truncates) when the window is larger than the client memory bound.
    public func pushRecords(stream: PushStream, deviceId: String, window: PushWindow) throws -> [PushRecord] {
        try dbWriter.read { db in
            let present = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(stream.rawValue))").map { $0["name"] as String })
            let columns = stream.keyColumns + stream.dataColumns
            let projection = columns.map { present.contains($0) ? "\"\($0)\"" : "NULL AS \"\($0)\"" }.joined(separator: ", ")
            let predicate: String
            let arguments: StatementArguments
            switch stream.selector {
            case .day:
                predicate = "day >= ? AND day < ?"
                arguments = [deviceId, window.fromDay, window.endExclusiveDay, PushProtocol.maxSnapshotRecords + 1]
            case .startTs:
                predicate = "startTs >= ? AND startTs < ?"
                arguments = [deviceId, window.startTsInclusive, window.endTsExclusive, PushProtocol.maxSnapshotRecords + 1]
            }
            let order = stream.keyColumns.map { "\"\($0)\"" }.joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: "SELECT \(projection) FROM \(stream.rawValue) WHERE deviceId = ? AND \(predicate) ORDER BY \(order) LIMIT ?",
                                        arguments: arguments)
            if rows.count > PushProtocol.maxSnapshotRecords {
                throw PushProtocolError("\(stream.rawValue) window has more than \(PushProtocol.maxSnapshotRecords) rows")
            }
            var bytes = 0
            return try rows.map { row in
                func value(_ column: String) -> PushValue {
                    let dbValue: DatabaseValue = row[column]
                    switch dbValue.storage {
                    case .null: return .null
                    case .int64(let i): return stream.booleanColumns.contains(column) ? .bool(i != 0) : .int(i)
                    case .double(let d): return .double(d)
                    case .string(let s): return .string(s)
                    case .blob: return .null
                    }
                }
                let record = PushRecord(key: Dictionary(uniqueKeysWithValues: stream.keyColumns.map { ($0, value($0)) }),
                                        data: Dictionary(uniqueKeysWithValues: stream.dataColumns.map { ($0, value($0)) }))
                bytes += try PushProtocol.encodedSize(stream: stream, record: record)
                if bytes > PushProtocol.maxSnapshotBytes {
                    throw PushProtocolError("\(stream.rawValue) window is larger than 2 MiB")
                }
                return record
            }
        }
    }
}
