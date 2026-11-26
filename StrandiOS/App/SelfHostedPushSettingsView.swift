#if os(iOS)
import SwiftUI
import StrandDesign

/// More › Self-hosted Push: the opt-in screen for the Experimental one-way export to a receiver that the
/// user owns (docs/PUSH_PROTOCOL.md). Default OFF. NOOP ships no receiver and reads nothing back.
struct SelfHostedPushSettingsView: View {
    @ObservedObject private var push = SelfHostedPushController.shared
    @AppStorage(SelfHostedPushController.enabledKey) private var enabled = false
    @State private var endpoint = SelfHostedPushController.shared.endpointText
    @State private var tokenDraft = ""
    @State private var hasToken = SelfHostedPushController.shared.hasToken
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        ScreenScaffold(title: "Self-hosted Push",
                       subtitle: "Experimental. Send your daily numbers one way to a server that you own.") {
            setupCard
            statusCard
        }
    }

    private var setupCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $enabled) {
                    Text("Push to my receiver")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChange(of: enabled) { _, on in if on { push.trigger() } }

                field("Receiver address") {
                    TextField("https://my-server.example/noop", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(saveEndpoint)
                }
                field(hasToken ? "Bearer token (saved)" : "Bearer token") {
                    SecureField(hasToken ? "Paste a new token to replace it" : "Paste the receiver's token", text: $tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveToken)
                }

                HStack(spacing: 10) {
                    NoopButton("Save", systemImage: "checkmark", kind: .primary) {
                        saveEndpoint()
                        saveToken()
                    }
                    NoopButton("Test connection", systemImage: "network", kind: .secondary) {
                        saveEndpoint()
                        saveToken()
                        testing = true
                        Task {
                            testResult = await push.testConnection()
                            testing = false
                        }
                    }
                    .disabled(testing)
                }
                if let testResult {
                    Text(testResult)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("NOOP sends the last 14 days of daily metrics, sleeps, workouts and journal answers after each strap sync, and only the days that changed. Raw heart-rate samples are not sent. The token stays in this iPhone's Keychain. NOOP does not run a server, and it never reads data back from yours.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Last push").strandOverline()
                Text(push.lastStatus)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let at = push.lastRunAt {
                    Text(at, format: .dateTime.month().day().hour().minute())
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                HStack(spacing: 10) {
                    NoopButton(push.running ? "Pushing…" : "Push now", systemImage: "arrow.up.circle", kind: .secondary) {
                        saveEndpoint()
                        push.trigger()
                    }
                    .disabled(!enabled || push.running)
                    NoopButton("Send all 14 days again", systemImage: "arrow.clockwise", kind: .tertiary) {
                        push.resetProgress()
                        push.trigger()
                    }
                    .disabled(!enabled || push.running)
                }
            }
        }
    }

    private func field<Content: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            content()
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
    }

    private func saveEndpoint() {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != push.endpointText {
            push.endpointText = trimmed
            push.resetProgress()
        }
    }

    private func saveToken() {
        guard !tokenDraft.isEmpty else { return }
        if push.saveToken(tokenDraft) {
            tokenDraft = ""
            hasToken = true
        }
    }
}
#endif
