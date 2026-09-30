import SwiftUI
import Combine
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import StrandDesign

// MARK: - CloudEnrollmentModel

/// Drives `CloudEnrollmentView`: owns the `EnrollmentState` and talks to the enrollment client.
/// This is the opt-in cloud path — the app stays fully offline until the user enrolls and enables it.
@MainActor
public final class CloudEnrollmentModel: ObservableObject {

    /// The state the view renders.
    @Published public private(set) var state: EnrollmentState

    /// The enrollment code as typed (canonicalization happens in the client before the request).
    @Published public var codeInput = ""

    /// Mirrors `CloudPushSettings.isEnabled` so the toggle re-renders when it flips.
    @Published public private(set) var isCloudEnabled: Bool

    /// The injectable enrollment client (defaults to the real receiver via `CloudPushSettings`).
    public let client: CloudEnrollmentClient

    /// The app version reported at enrollment (1…64 chars, no control characters).
    public let appVersion: String

    public init(client: CloudEnrollmentClient = CloudEnrollmentClient(), appVersion: String? = nil) {
        self.client = client
        self.appVersion = appVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "unknown"
        self.isCloudEnabled = CloudPushSettings.isEnabled
        self.state = Self.restoredState()
    }

    /// True when this build carries a receiver endpoint + fleet token (enrollment can actually run).
    public var isConfigured: Bool { CloudPushSettings.isConfigured }

    /// The OS this installation runs on — the receiver only accepts `ios` / `macos`.
    public var platform: CloudEnrollmentPlatform {
        #if os(iOS)
        return .ios
        #else
        return .macos
        #endif
    }

    /// If this install already holds an identity, resume straight into the enrolled state.
    private static func restoredState() -> EnrollmentState {
        guard let identity = CloudPushIdentityStore.current() else { return .notEnrolled }
        return .enrolled(ownerId: identity.ownerId, sourceId: identity.sourceId,
                         protocolVersion: CloudEnrollment.currentProtocolVersion())
    }

    // MARK: - Actions

    public func enroll() {
        guard !state.isEnrolling else { return }
        let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        state = .enrolling
        Task { await runEnrollment(code: code) }
    }

    /// Re-run enrollment with the code still in the field. Only offered for retryable failures.
    public func retry() { enroll() }

    /// Return to the code form (e.g. after a non-retryable failure) to edit the code.
    public func resetForm() { state = .notEnrolled }

    /// Read the platform pasteboard into the code field.
    public func pasteCode() {
        #if canImport(AppKit)
        if let string = NSPasteboard.general.string(forType: .string) {
            codeInput = string
        }
        #elseif canImport(UIKit)
        if let string = UIPasteboard.general.string {
            codeInput = string
        }
        #endif
    }

    /// Turn cloud mode on. The credential stays enrolled; this only lifts the master switch.
    public func enableCloud() {
        CloudPushSettings.setEnabled(true)
        isCloudEnabled = true
    }

    /// Turn cloud mode off. Uploads stop; the enrollment credential is kept so it can be re-enabled.
    public func disableCloud() {
        CloudPushSettings.setEnabled(false)
        isCloudEnabled = false
    }

    // MARK: - Enrollment

    private func runEnrollment(code: String) async {
        do {
            _ = try await client.enroll(code: code, appVersion: appVersion, platform: platform)
            guard let identity = CloudPushIdentityStore.current() else {
                state = .failed(message: String(localized: "Enrollment didn't save. Try again."), retryable: true)
                return
            }
            state = .enrolled(ownerId: identity.ownerId, sourceId: identity.sourceId,
                              protocolVersion: CloudEnrollment.currentProtocolVersion())
        } catch let error as CloudEnrollmentError {
            state = .failed(message: error.errorDescription ?? String(localized: "Enrollment failed."),
                            retryable: error.retryable)
        } catch {
            state = .failed(message: String(localized: "Enrollment failed. Try again."), retryable: true)
        }
    }
}

// MARK: - CloudEnrollmentView

/// A compact, opt-in screen for enrolling this installation into the hosted-compute cloud path.
///
/// Cloud mode is OFF until the user enrolls and then enables it. The screen explains what cloud mode
/// does, takes the enrollment code (with paste support), renders `EnrollmentState` (progress,
/// enrolled owner/source/protocol, and typed failures with Retry only when retryable), and exposes
/// enable / disable controls over `CloudPushSettings`.
public struct CloudEnrollmentView: View {

    @StateObject private var model: CloudEnrollmentModel

    /// Build a view with a fresh model (real receiver from `CloudPushSettings`).
    @MainActor
    public init() {
        _model = StateObject(wrappedValue: CloudEnrollmentModel())
    }

    /// Build a view with an injected model (tests / previews / shared settings).
    @MainActor
    public init(model: CloudEnrollmentModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                explanationCard

                switch model.state {
                case .notEnrolled:
                    enrollmentCard
                case .enrolling:
                    enrollingCard
                case .enrolled(let ownerId, let sourceId, let protocolVersion):
                    enrolledCard(ownerId: ownerId, sourceId: sourceId, protocolVersion: protocolVersion)
                case .failed(let message, let retryable):
                    failedCard(message: message, retryable: retryable)
                }
            }
            .frame(maxWidth: 560)
            .padding(.vertical, 24)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    // MARK: Explanation

    private var explanationCard: some View {
        StrandCard {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(StrandPalette.accent.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cloud mode").font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Cloud mode uploads measured strap data to your hosted project, where it is scored on the server. Nothing is sent until you enroll and turn it on.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 520)
    }

    // MARK: Not enrolled — code form

    private var enrollmentCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enroll").font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Enter the enrollment code you were given for this project.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }

                HStack(spacing: 10) {
                    TextField("NARA-XXXX-XXXX-XXXX-XXXX-XXXX", text: $model.codeInput)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        #if os(iOS)
                        .autocapitalization(.allCharacters)
                        #endif
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(NoopPanelSurface(cornerRadius: 10))
                    NoopButton("Paste", systemImage: "doc.on.clipboard", kind: .secondary, action: model.pasteCode)
                }

                if !model.isConfigured {
                    Text("This build has no cloud endpoint configured, so enrollment can't run.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NoopButton("Enroll", systemImage: "key", kind: .primary, fullWidth: true, action: model.enroll)
                    .disabled(model.codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.isConfigured)
            }
        }
        .frame(maxWidth: 520)
    }

    // MARK: Enrolling

    private var enrollingCard: some View {
        StrandCard {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small).tint(StrandPalette.accent)
                Text("Enrolling this installation…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 520)
    }

    // MARK: Enrolled — success + cloud switch

    private func enrolledCard(ownerId: String, sourceId: String, protocolVersion: String) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    StatePill("Enrolled", tone: .positive)
                    Spacer()
                    Text("protocol \(protocolVersion)")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Owner").strandOverline()
                    Text(shortIdentifier(ownerId))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Source").strandOverline().padding(.top, 6)
                    Text(shortIdentifier(sourceId))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                Divider().overlay(StrandPalette.hairline)

                if model.isCloudEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            StatePill("Cloud on", tone: .positive)
                            Text("Measured data uploads when captured.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        NoopButton("Disable cloud", systemImage: "icloud.slash", kind: .secondary,
                                   fullWidth: true, action: model.disableCloud)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Cloud mode is off until you enable it.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        NoopButton("Enable cloud", systemImage: "icloud.and.arrow.up", kind: .primary,
                                   fullWidth: true, action: model.enableCloud)
                    }
                }
            }
        }
        .frame(maxWidth: 520)
    }

    // MARK: Failed — typed message + Retry when retryable

    private func failedCard(message: String, retryable: Bool) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusCritical)
                    Text("Enrollment failed").font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if retryable {
                    NoopButton("Retry", systemImage: "arrow.clockwise", kind: .primary,
                               fullWidth: true, action: model.retry)
                } else {
                    NoopButton("Change code", systemImage: "square.and.pencil", kind: .secondary,
                               fullWidth: true, action: model.resetForm)
                }
            }
        }
        .frame(maxWidth: 520)
    }

    /// First 8 characters of a UUID — enough to recognise the binding without flooding the card.
    private func shortIdentifier(_ value: String) -> String {
        String(value.prefix(8))
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Cloud enrollment") {
    CloudEnrollmentView(model: CloudEnrollmentModel(
        client: CloudEnrollmentClient(endpoint: URL(string: "https://example.invalid/push")),
        appVersion: "11.8.0"
    ))
    .frame(width: 480, height: 720)
}
#endif
