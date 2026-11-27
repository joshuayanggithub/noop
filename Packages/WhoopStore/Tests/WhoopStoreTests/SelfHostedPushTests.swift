import XCTest
import GRDB
@testable import WhoopStore

final class SelfHostedPushTests: XCTestCase {
    static let source = "3a3486dd-5030-4e17-a00d-a781399890f9"
    static let state = "5fc7b9a0-8055-4e49-a308-3a290f98d81a"

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - SHA-256 (FIPS 180-4 test vectors)

    func testSha256KnownVectors() {
        XCTAssertEqual(SHA256Digest.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256Digest.hex(Data(repeating: 0x61, count: 1_000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        // The plain-Swift path (used where CryptoKit is absent) gives the same digests.
        for input in [Data(), Data("abc".utf8), Data(repeating: 0x61, count: 1_000), Data((0..<200).map { UInt8($0) })] {
            XCTAssertEqual(SHA256Digest.portableHash(input), SHA256Digest.hash(input))
        }
    }

    // MARK: - Encoding

    func dailyRecord(_ day: String, sleep: Double? = 420.5, rhr: Int64? = 52) -> PushRecord {
        var data = Dictionary(uniqueKeysWithValues: PushStream.dailyMetric.dataColumns.map { ($0, PushValue.null) })
        if let sleep { data["totalSleepMin"] = .double(sleep) }
        if let rhr { data["restingHr"] = .int(rhr) }
        return PushRecord(key: ["day": .string(day)], data: data)
    }

    func window(_ from: String, _ to: String) -> PushWindow {
        let f = ISO8601DateFormatter()
        return PushWindow.days(from: f.date(from: from + "T00:00:00Z")!, to: f.date(from: to + "T00:00:00Z")!, calendar: utc)
    }

    func lines(_ batch: PushBatch) -> [[String: Any]] {
        String(decoding: batch.body, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast().map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    func testReplacementBatchHasTheV1HeaderAndSortedRecords() throws {
        let w = window("2026-11-20", "2026-11-21")
        let batches = try PushProtocol.replacementBatches(stream: .dailyMetric, sourceId: Self.source, deviceId: "my-whoop",
                                                          window: w, records: [dailyRecord("2026-11-21"), dailyRecord("2026-11-20")])
        XCTAssertEqual(batches.count, 1)
        let body = String(decoding: batches[0].body, as: UTF8.self)
        XCTAssertTrue(body.hasSuffix("\n") && !body.contains("\n\n"))
        let parsed = lines(batches[0])
        XCTAssertEqual(parsed.count, 3)
        let header = parsed[0]
        XCTAssertEqual(header["type"] as? String, "batch")
        XCTAssertEqual(header["protocolVersion"] as? String, "1.0")
        XCTAssertEqual(header["batchId"] as? String, batches[0].batchId)
        XCTAssertEqual(header["delivery"] as? String, "replace_window")
        XCTAssertEqual(header["recordCount"] as? Int, 2)
        XCTAssertTrue(header["startCursor"] is NSNull && header["endCursor"] is NSNull)
        let windowJSON = header["window"] as! [String: Any]
        XCTAssertEqual(windowJSON["selector"] as? String, "day")
        XCTAssertEqual(windowJSON["startInclusive"] as? String, "2026-11-20")
        XCTAssertEqual(windowJSON["endExclusive"] as? String, "2026-11-22")
        XCTAssertEqual(windowJSON["part"] as? Int, 1)
        XCTAssertEqual(windowJSON["parts"] as? Int, 1)
        XCTAssertEqual((parsed[1]["key"] as! [String: Any])["day"] as? String, "2026-11-20")
        let data = parsed[1]["data"] as! [String: Any]
        XCTAssertEqual(data["totalSleepMin"] as? Double, 420.5)
        XCTAssertEqual(data["restingHr"] as? Int, 52)
        XCTAssertTrue(data["steps"] is NSNull)
        XCTAssertEqual(data.count, 18)
        XCTAssertTrue(UUID(uuidString: batches[0].batchId) != nil && batches[0].batchId == batches[0].batchId.lowercased())
        // The same rows give the same batch ID: a retry repeats the identical entity.
        let again = try PushProtocol.replacementBatches(stream: .dailyMetric, sourceId: Self.source, deviceId: "my-whoop",
                                                        window: w, records: [dailyRecord("2026-11-20"), dailyRecord("2026-11-21")])
        XCTAssertEqual(again, batches)
    }

    func testBooleansAreJsonBooleans() throws {
        var data = Dictionary(uniqueKeysWithValues: PushStream.journal.dataColumns.map { ($0, PushValue.null) })
        data["answeredYes"] = .bool(true)
        let batch = try PushProtocol.replacementBatches(stream: .journal, sourceId: Self.source, deviceId: "d",
                                                        window: window("2026-11-20", "2026-11-20"),
                                                        records: [PushRecord(key: ["day": .string("2026-11-20"), "question": .string("alcohol")], data: data)])[0]
        XCTAssertTrue(String(decoding: batch.body, as: UTF8.self).contains("\"answeredYes\":true"))
    }

    func testEmptyWindowIsOneAuthoritativeEmptyPart() throws {
        let batches = try PushProtocol.replacementBatches(stream: .workout, sourceId: Self.source, deviceId: "d",
                                                          window: window("2026-11-20", "2026-11-20"), records: [])
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].recordCount, 0)
        let header = lines(batches[0])[0]
        let w = header["window"] as! [String: Any]
        XCTAssertEqual(w["selector"] as? String, "startTs")
        XCTAssertEqual(w["startInclusive"] as? Int, 1_795_132_800)
        XCTAssertEqual(w["endExclusive"] as? Int, 1_795_132_800 + 86_400)
    }

    func testBadRecordsFailBeforeAnythingIsEncoded() {
        let w = window("2026-11-20", "2026-11-20")
        XCTAssertThrowsError(try PushProtocol.replacementBatches(stream: .dailyMetric, sourceId: Self.source, deviceId: "d", window: w,
                                                                 records: [dailyRecord("2026-11-20"), dailyRecord("2026-11-20")]))
        XCTAssertThrowsError(try PushProtocol.replacementBatches(stream: .dailyMetric, sourceId: Self.source, deviceId: "d", window: w,
                                                                 records: [dailyRecord("2026-11-20", sleep: .nan)]))
        var missing = dailyRecord("2026-11-20")
        missing.data.removeValue(forKey: "steps")
        XCTAssertThrowsError(try PushProtocol.replacementBatches(stream: .dailyMetric, sourceId: Self.source, deviceId: "d", window: w,
                                                                 records: [missing]))
        XCTAssertThrowsError(try PushProtocol.replacementBatches(stream: .dailyMetric, sourceId: Self.source.uppercased(), deviceId: "d",
                                                                 window: w, records: []))
    }

    func testLargeReplacementIsSplitIntoBoundedParts() throws {
        let note = String(repeating: "x", count: 900_000)
        let records: [PushRecord] = (0..<6).map { i in
            var data = Dictionary(uniqueKeysWithValues: PushStream.workout.dataColumns.map { ($0, PushValue.null) })
            data["endTs"] = .int(1_795_132_800 + Int64(i) * 60 + 30)
            data["source"] = .string("noop")
            data["notes"] = .string(note)
            return PushRecord(key: ["startTs": .int(1_795_132_800 + Int64(i) * 60), "sport": .string("run")], data: data)
        }
        let batches = try PushProtocol.replacementBatches(stream: .workout, sourceId: Self.source, deviceId: "d",
                                                          window: window("2026-11-20", "2026-11-20"), records: records)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.map(\.recordCount).reduce(0, +), 6)
        XCTAssertTrue(batches.allSatisfy { $0.body.count <= PushProtocol.maxBodyBytes && $0.parts == 2 })
        XCTAssertEqual(Set(batches.map(\.replacementId)).count, 1)
        XCTAssertEqual(Set(batches.map(\.batchId)).count, 2)
    }

    // MARK: - Receiver responses

    func testCapabilitiesAreParsedStrictly() throws {
        let good = #"{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\#(Self.state)","streams":["dailyMetric","hrSample"],"extra":1}"#
        XCTAssertEqual(try PushCapabilities.parse(Data(good.utf8)).streams, ["dailyMetric", "hrSample"])
        for bad in [
            #"{"type":"capabilities","protocolVersion":"2.0","receiverStateId":"\#(Self.state)","streams":[]}"#,
            #"{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\#(Self.state.uppercased())","streams":[]}"#,
            #"{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\#(Self.state)","streams":["steps"]}"#,
            #"{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"\#(Self.state)","streams":["journal","journal"]}"#,
            #"{"protocolVersion":"1.0","receiverStateId":"\#(Self.state)","streams":[]}"#,
            "not json",
        ] {
            XCTAssertThrowsError(try PushCapabilities.parse(Data(bad.utf8)), bad)
        }
    }

    func testAcknowledgementMustMatchExactly() throws {
        let batch = try PushProtocol.replacementBatches(stream: .dailyMetric, sourceId: Self.source, deviceId: "my-whoop",
                                                        window: window("2026-11-20", "2026-11-20"), records: [dailyRecord("2026-11-20")])[0]
        func ack(_ change: (inout [String: Any]) -> Void = { _ in }) -> Data {
            var object: [String: Any] = ["protocolVersion": "1.0", "batchId": batch.batchId, "stream": "dailyMetric",
                                         "deviceId": "my-whoop", "endCursor": NSNull(), "acceptedRows": 1, "status": "accepted"]
            change(&object)
            return try! JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertTrue(PushAck.matches(ack(), batch: batch))
        XCTAssertFalse(PushAck.matches(ack { $0["acceptedRows"] = 0 }, batch: batch))
        XCTAssertFalse(PushAck.matches(ack { $0["acceptedRows"] = true }, batch: batch))
        XCTAssertFalse(PushAck.matches(ack { $0["batchId"] = Self.state }, batch: batch))
        XCTAssertFalse(PushAck.matches(ack { $0.removeValue(forKey: "endCursor") }, batch: batch))
        XCTAssertFalse(PushAck.matches(ack { $0["status"] = "queued" }, batch: batch))
        XCTAssertFalse(PushAck.matches(ack { $0["commands"] = [] }, batch: batch))
        XCTAssertEqual(PushAck.errorCode(Data(#"{"type":"error","protocolVersion":"1.0","code":"registry_mismatch"}"#.utf8)), "registry_mismatch")
        XCTAssertNil(PushAck.errorCode(Data(#"{"type":"error","code":"Bad Code"}"#.utf8)))
    }

    func testEndpointRule() {
        XCTAssertNotNil(PushEndpointPolicy.validate("https://joshua-desktop.example.ts.net:8379/noop"))
        XCTAssertNotNil(PushEndpointPolicy.validate("http://192.168.86.184:8379/noop"))
        XCTAssertNotNil(PushEndpointPolicy.validate("http://127.0.0.1/noop"))
        XCTAssertNotNil(PushEndpointPolicy.validate("http://[fd12::1]/noop"))
        XCTAssertNil(PushEndpointPolicy.validate("http://joshua-desktop.local/noop"))
        XCTAssertNil(PushEndpointPolicy.validate("http://100.95.3.65/noop"))
        XCTAssertNil(PushEndpointPolicy.validate("http://8.8.8.8/noop"))
        XCTAssertNil(PushEndpointPolicy.validate("https://user:pw@example.com/noop"))
        XCTAssertNil(PushEndpointPolicy.validate("ftp://192.168.1.1/"))
        XCTAssertEqual(PushEndpointPolicy.normalized(URL(string: "HTTPS://Host.Example:443")!), "https://host.example/")
    }

    // MARK: - Reads

    func testReadsUseTheRegistryColumnsOnly() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, totalSleepMin, restingHr, recovery) VALUES ('my-whoop-noop', '2026-11-20', 431.5, 51, 72.0)")
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, totalSleepMin) VALUES ('my-whoop-noop', '2026-11-10', 300)")
            try db.execute(sql: "INSERT INTO sleepSession (deviceId, startTs, endTs, userEdited) VALUES ('my-whoop-noop', 1795132900, 1795160000, 1)")
            try db.execute(sql: "INSERT INTO workout (deviceId, startTs, endTs, sport, source, durationS) VALUES ('my-whoop', 1795140000, 1795143600, 'run', 'noop', 3600)")
        }
        let w = window("2026-11-20", "2026-11-20")
        let daily = try await store.pushRecords(stream: .dailyMetric, deviceId: "my-whoop-noop", window: w)
        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily[0].data["totalSleepMin"], .double(431.5))
        XCTAssertEqual(daily[0].data["restingHr"], .int(51))
        XCTAssertEqual(daily[0].data["steps"], .null)
        XCTAssertEqual(Set(daily[0].data.keys), Set(PushStream.dailyMetric.dataColumns))
        let sleep = try await store.pushRecords(stream: .sleepSession, deviceId: "my-whoop-noop", window: w)
        XCTAssertEqual(sleep.first?.data["userEdited"], .bool(true))
        let workouts = try await store.pushRecords(stream: .workout, deviceId: "my-whoop", window: w)
        XCTAssertEqual(workouts.first?.key["sport"], .string("run"))
        XCTAssertEqual(Set(workouts.first!.data.keys), Set(PushStream.workout.dataColumns))
        let ids = try await store.pushDeviceIds(streams: PushStream.allCases)
        XCTAssertEqual(ids, ["my-whoop", "my-whoop-noop"])
    }

    // MARK: - Runner

    /// A minimal receiver that keeps what it was sent and can be told to fail.
    final class FakeReceiver: PushTransport, @unchecked Sendable {
        var streams = ["dailyMetric", "sleepSession", "workout", "journal"]
        var state = SelfHostedPushTests.state
        var bodies: [Data] = []
        var badAck = false
        var authorizations: Set<String> = []

        func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
            authorizations.insert(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if request.httpMethod == "GET" {
                let doc: [String: Any] = ["type": "capabilities", "protocolVersion": "1.0", "receiverStateId": state, "streams": streams]
                return (200, try JSONSerialization.data(withJSONObject: doc))
            }
            let body = request.httpBody!
            bodies.append(body)
            let header = try JSONSerialization.jsonObject(with: body.prefix { $0 != 0x0a }) as! [String: Any]
            let ack: [String: Any] = ["protocolVersion": "1.0", "batchId": header["batchId"]!, "stream": header["stream"]!,
                                      "deviceId": header["deviceId"]!, "endCursor": header["endCursor"] ?? NSNull(),
                                      "acceptedRows": badAck ? 0 : header["recordCount"]!, "status": "accepted"]
            return (200, try JSONSerialization.data(withJSONObject: ack))
        }

        func headers() -> [[String: Any]] {
            bodies.map { try! JSONSerialization.jsonObject(with: $0.prefix { $0 != 0x0a }) as! [String: Any] }
        }
    }

    func testRunSendsABaselineThenOnlyTheChangedDays() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, totalSleepMin) VALUES ('my-whoop-noop', '2026-11-20', 431)")
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, totalSleepMin) VALUES ('my-whoop-noop', '2026-11-24', 400)")
        }
        let receiver = FakeReceiver()
        receiver.streams = ["dailyMetric"]
        let runner = SelfHostedPushRunner(endpoint: URL(string: "https://receiver.example/noop")!, token: "t0ken",
                                          sourceId: Self.source, transport: receiver, calendar: utc)
        let now = ISO8601DateFormatter().date(from: "2026-11-25T18:00:00Z")!
        var progress = PushProgress()

        var report = await runner.run(store: store, progress: &progress, now: now)
        XCTAssertTrue(report.ok, "\(report.failures)")
        XCTAssertEqual(receiver.headers().count, 1)
        var w = receiver.headers()[0]["window"] as! [String: Any]
        XCTAssertEqual(w["startInclusive"] as? String, "2026-11-12")
        XCTAssertEqual(w["endExclusive"] as? String, "2026-11-26")
        XCTAssertEqual(receiver.headers()[0]["recordCount"] as? Int, 2)
        XCTAssertEqual(receiver.authorizations, ["Bearer t0ken"])

        report = await runner.run(store: store, progress: &progress, now: now)
        XCTAssertEqual(receiver.bodies.count, 1, "nothing changed, nothing is sent")
        XCTAssertEqual(report.unchanged, 1)

        // One day changes; a formerly populated day becomes empty. The smallest window covers both.
        try await store.registryWriter.write { db in
            try db.execute(sql: "UPDATE dailyMetric SET totalSleepMin = 401 WHERE day = '2026-11-24'")
            try db.execute(sql: "DELETE FROM dailyMetric WHERE day = '2026-11-20'")
        }
        report = await runner.run(store: store, progress: &progress, now: now)
        XCTAssertTrue(report.ok)
        w = receiver.headers()[1]["window"] as! [String: Any]
        XCTAssertEqual(w["startInclusive"] as? String, "2026-11-20")
        XCTAssertEqual(w["endExclusive"] as? String, "2026-11-25")
        XCTAssertEqual(receiver.headers()[1]["recordCount"] as? Int, 1)
    }

    func testFailedAcknowledgementKeepsProgressAndANewReceiverStateSendsTheBaseline() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, totalSleepMin) VALUES ('my-whoop-noop', '2026-11-24', 400)")
        }
        let receiver = FakeReceiver()
        receiver.streams = ["dailyMetric"]
        receiver.badAck = true
        let runner = SelfHostedPushRunner(endpoint: URL(string: "https://receiver.example/noop")!, token: "t",
                                          sourceId: Self.source, transport: receiver, calendar: utc)
        let now = ISO8601DateFormatter().date(from: "2026-11-25T18:00:00Z")!
        var progress = PushProgress()
        var report = await runner.run(store: store, progress: &progress, now: now)
        XCTAssertFalse(report.ok)
        XCTAssertEqual(progress, PushProgress())

        receiver.badAck = false
        report = await runner.run(store: store, progress: &progress, now: now)
        XCTAssertTrue(report.ok)
        XCTAssertEqual(receiver.bodies[0], receiver.bodies[1], "the retry repeats the identical entity")

        receiver.state = "bf8b735e-f157-4a35-beb2-9b086d10d5bd"
        report = await runner.run(store: store, progress: &progress, now: now)
        XCTAssertEqual(receiver.bodies.count, 3, "a new receiver state gets the full baseline again")
    }

    func testStreamsTheReceiverDoesNotListAreNotRead() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, totalSleepMin) VALUES ('my-whoop-noop', '2026-11-24', 400)")
        }
        let receiver = FakeReceiver()
        receiver.streams = ["gravitySample"]
        let runner = SelfHostedPushRunner(endpoint: URL(string: "https://receiver.example/noop")!, token: "t",
                                          sourceId: Self.source, transport: receiver, calendar: utc)
        var progress = PushProgress()
        let report = await runner.run(store: store, progress: &progress)
        XCTAssertTrue(report.ok)
        XCTAssertTrue(receiver.bodies.isEmpty)
    }

    // MARK: - Append streams

    func hrRow(_ rowId: Int64, ts: Int64, bpm: Int64) -> PushAppendRow {
        PushAppendRow(rowId: rowId, record: PushRecord(key: ["ts": .int(ts)], data: ["bpm": .int(bpm)]))
    }

    func testAppendBatchesCarryChainedCursors() throws {
        let rows = (1...5_001).map { hrRow(Int64($0) + 100, ts: 1_795_132_800 + Int64($0), bpm: 60) }
        let batches = try PushProtocol.appendBatches(stream: .hrSample, sourceId: Self.source, deviceId: "my-whoop",
                                                     startCursor: nil, rows: rows)
        XCTAssertEqual(batches.map(\.recordCount), [5_000, 1])
        XCTAssertNil(batches[0].startCursor)
        XCTAssertEqual(batches[1].startCursor, batches[0].endCursor)
        XCTAssertEqual(batches[0].endCursor.rowId, 5_100)
        XCTAssertEqual(batches[1].endCursor.rowId, 5_101)
        let header = try JSONSerialization.jsonObject(with: batches[1].body.prefix { $0 != 0x0a }) as! [String: Any]
        XCTAssertEqual(header["delivery"] as? String, "append")
        XCTAssertNil(header["window"])
        XCTAssertEqual((header["startCursor"] as! [String: Any])["rowId"] as? Int, 5_100)
        XCTAssertEqual((header["endCursor"] as! [String: Any])["keySha256"] as? String, batches[1].endCursor.keySha256)
        // The fingerprint is over stream LF device LF the key in registry order (ts, rrMs, seq), not sorted.
        XCTAssertEqual(PushProtocol.cursorKeySha256(stream: .rrInterval, deviceId: "d", key: ["seq": .int(0), "ts": .int(5), "rrMs": .int(800)]),
                       SHA256Digest.hex(Data("rrInterval\nd\n{\"ts\":5,\"rrMs\":800,\"seq\":0}".utf8)))
        let again = try PushProtocol.appendBatches(stream: .hrSample, sourceId: Self.source, deviceId: "my-whoop",
                                                   startCursor: nil, rows: rows)
        XCTAssertEqual(again, batches, "a retry repeats the identical entity")
        // Out of insertion order, a null bpm, or a missing column fails before anything is encoded.
        XCTAssertThrowsError(try PushProtocol.appendBatches(stream: .hrSample, sourceId: Self.source, deviceId: "d", startCursor: nil,
                                                            rows: [hrRow(5, ts: 1, bpm: 60), hrRow(4, ts: 2, bpm: 60)]))
        XCTAssertThrowsError(try PushProtocol.appendBatches(stream: .hrSample, sourceId: Self.source, deviceId: "d", startCursor: nil,
                                                            rows: [PushAppendRow(rowId: 1, record: PushRecord(key: ["ts": .int(1)], data: ["bpm": .null]))]))
        XCTAssertNoThrow(try PushProtocol.appendBatches(stream: .rrInterval, sourceId: Self.source, deviceId: "d", startCursor: nil, rows: [
            PushAppendRow(rowId: 1, record: PushRecord(key: ["ts": .int(1), "rrMs": .int(800), "seq": .int(0)],
                                                       data: ["ord": .null, "srcChannel": .int(5), "tsSuspect": .null]))]))
    }

    func testAppendAcknowledgementMustEchoTheEndCursor() throws {
        let batch = try PushProtocol.appendBatches(stream: .hrSample, sourceId: Self.source, deviceId: "my-whoop", startCursor: nil,
                                                   rows: [hrRow(7, ts: 1_795_132_800, bpm: 61)])[0]
        func ack(_ change: (inout [String: Any]) -> Void = { _ in }) -> Data {
            var object: [String: Any] = ["protocolVersion": "1.0", "batchId": batch.batchId, "stream": "hrSample", "deviceId": "my-whoop",
                                         "endCursor": ["rowId": 7, "keySha256": batch.endCursor.keySha256], "acceptedRows": 1, "status": "accepted"]
            change(&object)
            return try! JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertTrue(PushAck.matches(ack(), appendBatch: batch))
        XCTAssertFalse(PushAck.matches(ack { $0["endCursor"] = NSNull() }, appendBatch: batch))
        XCTAssertFalse(PushAck.matches(ack { $0["endCursor"] = ["rowId": 8, "keySha256": batch.endCursor.keySha256] }, appendBatch: batch))
        XCTAssertFalse(PushAck.matches(ack { $0["endCursor"] = ["rowId": 7, "keySha256": String(repeating: "a", count: 64)] }, appendBatch: batch))
        XCTAssertFalse(PushAck.matches(ack { $0["acceptedRows"] = 2 }, appendBatch: batch))
    }

    func testRunSendsTheHorizonOfAppendRowsThenOnlyNewRows() async throws {
        let store = try await WhoopStore.inMemory()
        let now = ISO8601DateFormatter().date(from: "2026-11-25T18:00:00Z")!
        let old = 1_795_132_800 - 30 * 86_400   // before the 14-day horizon
        let recent = 1_795_132_800              // 2026-11-20, inside it
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', ?, 70)", arguments: [old])
            for i in 0..<3 { try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', ?, ?)", arguments: [recent + i, 60 + i]) }
            try db.execute(sql: "INSERT INTO rrInterval (deviceId, ts, rrMs, seq, srcChannel) VALUES ('my-whoop', ?, 1000, 0, 5)", arguments: [recent])
        }
        let receiver = FakeReceiver()
        receiver.streams = ["hrSample", "rrInterval"]
        let runner = SelfHostedPushRunner(endpoint: URL(string: "https://receiver.example/noop")!, token: "t",
                                          sourceId: Self.source, transport: receiver, calendar: utc)
        var progress = PushProgress()
        var report = await runner.run(store: store, progress: &progress, now: now)
        XCTAssertTrue(report.ok, "\(report.failures)")
        XCTAssertEqual(receiver.headers().map { $0["stream"] as? String }, ["hrSample", "rrInterval"])
        XCTAssertEqual(receiver.headers().map { $0["recordCount"] as? Int }, [3, 1], "the row before the horizon is not sent")
        XCTAssertEqual(report.appendedRows, 4)
        let firstBody = String(decoding: receiver.bodies[1], as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#""data":{"ord":null,"srcChannel":5,"tsSuspect":null}"#), firstBody)

        report = await runner.run(store: store, progress: &progress, now: now)
        XCTAssertEqual(receiver.bodies.count, 2, "nothing new, nothing sent")

        // A later offload can insert an old time: insertion order, not time, decides what is new.
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('my-whoop', ?, 55)", arguments: [recent - 600])
        }
        report = await runner.run(store: store, progress: &progress, now: now)
        XCTAssertEqual(receiver.headers().last?["recordCount"] as? Int, 1)
        XCTAssertNotNil(receiver.headers().last?["startCursor"] as? [String: Any])

        // The row of the cursor is gone (a prune or a restore): the stream starts again at the horizon.
        try await store.registryWriter.write { db in
            try db.execute(sql: "DELETE FROM hrSample WHERE ts = ?", arguments: [recent - 600])
        }
        report = await runner.run(store: store, progress: &progress, now: now)
        XCTAssertTrue(report.ok)
        XCTAssertEqual(receiver.headers().last?["recordCount"] as? Int, 3)
        XCTAssertTrue(receiver.headers().last?["startCursor"] is NSNull)

        // Progress saved by the version before append streams still decodes.
        let older = #"{"namespaces":{"k":{"dayHashes":{},"devices":{"dailyMetric":["my-whoop"]}}}}"#
        let decoded = try JSONDecoder().decode(PushProgress.self, from: Data(older.utf8))
        XCTAssertEqual(decoded.namespaces["k"]?.devices["dailyMetric"], ["my-whoop"])
        XCTAssertEqual(decoded.namespaces["k"]?.cursors, [:])
    }
}
