#if os(iOS)
import Foundation
import Security
import UIKit
import WhoopStore

/// The iOS side of the Experimental self-hosted push (docs/PUSH_PROTOCOL.md, issue #1314).
///
/// Default OFF. With no endpoint it never runs, so it causes no network traffic and changes nothing.
/// When it is on, it runs after a strap offload (the same hook as the Apple Health write-back), on
/// foreground entry, and from the "Push now" button. A run is a separate task: the offload, the re-score
/// and the UI never wait for it, and a receiver that is slow or down costs only that run.
/// The protocol logic is `SelfHostedPushRunner` in WhoopStore; this type owns settings and scheduling.
@MainActor
final class SelfHostedPushController: ObservableObject {
    static let shared = SelfHostedPushController()

    static let enabledKey = "selfHostedPush.enabled"
    static let endpointKey = "selfHostedPush.endpoint"
    private static let sourceIdKey = "selfHostedPush.sourceId"
    private static let progressKey = "selfHostedPush.progress"
    private static let statusKey = "selfHostedPush.lastStatus"
    private static let lastRunKey = "selfHostedPush.lastRunAt"

    @Published private(set) var running = false
    @Published private(set) var lastStatus: String
    @Published private(set) var lastRunAt: Date?

    private var repo: Repository?
    private var pending = false
    private let defaults = UserDefaults.standard

    private init() {
        lastStatus = defaults.string(forKey: Self.statusKey) ?? "Not run yet."
        lastRunAt = defaults.object(forKey: Self.lastRunKey) as? Date
    }

    func configure(repo: Repository) { self.repo = repo }

    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    var endpointText: String {
        get { defaults.string(forKey: Self.endpointKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.endpointKey) }
    }

    var hasToken: Bool { PushTokenStore.load() != nil }

    @discardableResult
    func saveToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? false : PushTokenStore.save(trimmed)
    }

    func forgetToken() { PushTokenStore.clear() }

    /// The installation's random source ID. Made once; not an account and not sent anywhere else.
    private var sourceId: String {
        if let id = defaults.string(forKey: Self.sourceIdKey) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Self.sourceIdKey)
        return id
    }

    private func runner() -> SelfHostedPushRunner? {
        guard let url = PushEndpointPolicy.validate(endpointText), let token = PushTokenStore.load() else { return nil }
        return SelfHostedPushRunner(endpoint: url, token: token, sourceId: sourceId, transport: URLSessionPushTransport())
    }

    /// Start a run if the push is on. A trigger during a run is remembered and starts one more run after it.
    func trigger() {
        guard enabled else { return }
        if running {
            pending = true
            return
        }
        Task { await runLoop() }
    }

    /// The capabilities request alone; it reads no health data.
    func testConnection() async -> String {
        guard PushEndpointPolicy.validate(endpointText) != nil else { return Self.endpointHelp }
        guard let runner = runner() else { return "Save a token first." }
        do {
            let caps = try await runner.capabilities()
            let usable = PushStream.allCases.map(\.rawValue).filter(caps.streams.contains)
            return usable.isEmpty ? "Connected, but the receiver accepts none of NOOP's daily streams."
                                  : "Connected. The receiver accepts: \(usable.joined(separator: ", "))."
        } catch {
            return "Connection failed: \(error)"
        }
    }

    static let endpointHelp = "Use an https:// address, or http:// to a numeric private address (for example 192.168.1.20)."

    private func runLoop() async {
        repeat {
            pending = false
            await runOnce()
        } while pending && enabled
    }

    private func runOnce() async {
        guard let repo, let store = await repo.storeHandle() else { return finish("The local store is not open.") }
        guard PushEndpointPolicy.validate(endpointText) != nil else { return finish(Self.endpointHelp) }
        guard let runner = runner() else { return finish("Save a token first.") }
        running = true
        // A run that starts in the background asks iOS for the usual short extension, and ends it.
        let background = UIApplication.shared.beginBackgroundTask(withName: "noop.selfhostedpush") {}
        defer {
            running = false
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        var progress = loadProgress()
        let report = await runner.run(store: store, progress: &progress)
        saveProgress(progress)
        if report.ok {
            finish(report.sent.isEmpty ? "Up to date. Nothing changed since the last push."
                                       : "Sent \(report.sent.count) replacement\(report.sent.count == 1 ? "" : "s"); \(report.unchanged) unchanged.")
        } else {
            finish("Failed: " + report.failures.prefix(3).joined(separator: "; "))
        }
    }

    private func finish(_ status: String) {
        lastStatus = status
        lastRunAt = Date()
        defaults.set(status, forKey: Self.statusKey)
        defaults.set(lastRunAt, forKey: Self.lastRunKey)
    }

    private func loadProgress() -> PushProgress {
        guard let data = defaults.data(forKey: Self.progressKey),
              let progress = try? JSONDecoder().decode(PushProgress.self, from: data) else { return PushProgress() }
        return progress
    }

    private func saveProgress(_ progress: PushProgress) {
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: Self.progressKey) }
    }

    /// Turning the push off, or changing the endpoint, starts again from a full baseline next time.
    func resetProgress() { defaults.removeObject(forKey: Self.progressKey) }
}

/// The bearer token in the Keychain, never in UserDefaults. AfterFirstUnlock so a run after a background
/// offload can read it; ThisDeviceOnly so it is not in a backup.
enum PushTokenStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.noop.selfhostedpush",
         kSecAttrAccount as String: "bearer-token"]
    }

    static func save(_ token: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        var request = query
        request[kSecReturnData as String] = kCFBooleanTrue
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}
#endif
