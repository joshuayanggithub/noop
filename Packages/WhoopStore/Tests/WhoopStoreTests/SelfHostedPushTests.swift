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
                                      "deviceId": header["deviceId"]!, "endCursor": NSNull(),
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
        receiver.streams = ["hrSample"]
        let runner = SelfHostedPushRunner(endpoint: URL(string: "https://receiver.example/noop")!, token: "t",
                                          sourceId: Self.source, transport: receiver, calendar: utc)
        var progress = PushProgress()
        let report = await runner.run(store: store, progress: &progress)
        XCTAssertTrue(report.ok)
        XCTAssertTrue(receiver.bodies.isEmpty)
    }
}
