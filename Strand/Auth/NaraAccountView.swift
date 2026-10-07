import SwiftUI
import StrandDesign

/// The Nara account screen: create an account, enter the emailed code, choose between starting fresh and
/// recovering an enrollment-code account, sign in, reset a password, and, once signed in, see that this phone
/// is linked and switch cloud sync on or off.
///
/// Every state shown here comes from `NaraAuthService` (who is signed in) and `NaraAccountController` (is this
/// phone linked to them). The view holds no account logic of its own.
public struct NaraAccountView: View {

    @ObservedObject private var auth: NaraAuthService
    @ObservedObject private var account: NaraAccountController

    private enum Mode: Hashable { case create, signIn }
    private enum Field: Hashable { case email, password, code, newPassword, enrollmentCode }

    @State private var mode: Mode = .create
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var enrollmentCode = ""
    @State private var showsRecoveryEntry = false
    @State private var confirmSignOut = false
    @FocusState private var focus: Field?

    @MainActor
    public init() {
        _auth = ObservedObject(wrappedValue: NaraAuthService.shared)
        _account = ObservedObject(wrappedValue: NaraAccountController.shared)
    }

    @MainActor
    init(auth: NaraAuthService, account: NaraAccountController) {
        _auth = ObservedObject(wrappedValue: auth)
        _account = ObservedObject(wrappedValue: account)
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                if !isSignedIn { explanationCard }
                if !auth.isAvailable {
                    unavailableCard
                } else {
                    switch auth.phase {
                    case .restoring:
                        restoringCard
                    case .signedOut:
                        signedOutCard
                    case .awaitingSignupCode(let pending):
                        signupCodeCard(email: pending)
                    case .awaitingRecoveryCode(let pending):
                        recoveryCard(email: pending)
                    case .choosingSetup(let fresh):
                        setupChoiceCard(fresh)
                    case .signedIn(let signedIn):
                        signedInCards(signedIn)
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(.vertical, 24)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onAppear { applySuggestedEmail(auth.suggestedEmail) }
        .onChangeCompat(of: auth.suggestedEmail) { suggested in applySuggestedEmail(suggested) }
        .confirmationDialog("Sign out of Nara?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await account.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Data already recorded stays on this phone and keeps syncing to your account the next time you sign in.")
        }
    }

    private var isSignedIn: Bool {
        if case .signedIn = auth.phase { return true }
        return false
    }

    /// A flow that ended at the sign-in form (an email that already has an account, a recovery that needs
    /// a fresh sign-in) hands over the address so the person only types their password.
    private func applySuggestedEmail(_ suggested: String?) {
        guard let suggested else { return }
        email = suggested
        mode = .signIn
    }

    // MARK: Cards

    private var explanationCard: some View {
        StrandCard {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(StrandPalette.accent.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nara account").font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Sign in to sync your strap data and see your scores. Nothing is uploaded until you're signed in.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 520)
    }

    private var unavailableCard: some View {
        StrandCard {
            Text("Accounts aren't available in this version of Nara.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520)
    }

    private var restoringCard: some View {
        StrandCard {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small).tint(StrandPalette.accent)
                Text("Checking your sign-in…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: 520)
    }

    // MARK: Signed out

    private var signedOutCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 16) {
                Picker("", selection: $mode) {
                    Text("Create account").tag(Mode.create)
                    Text("Sign in").tag(Mode.signIn)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("nara.auth.mode")

                emailField
                passwordField(title: mode == .create ? "Password (8+ characters)" : "Password",
                              text: $password, field: .password,
                              isNew: mode == .create)

                messages

                NoopButton(mode == .create ? "Create account" : "Sign in",
                           systemImage: mode == .create ? "person.badge.plus" : "arrow.right.circle",
                           kind: .primary, fullWidth: true) {
                    focus = nil
                    Task {
                        if mode == .create {
                            await auth.signUp(email: email, password: password)
                        } else {
                            await auth.signIn(email: email, password: password)
                        }
                        if case .signedIn = auth.phase { password = "" }
                    }
                }
                .disabled(auth.isBusy || email.isEmpty || password.isEmpty)
                .accessibilityIdentifier("nara.auth.submit")

                if mode == .signIn {
                    NoopButton("Forgot password?", kind: .tertiary, fullWidth: true) {
                        focus = nil
                        Task { await auth.requestPasswordReset(email: email) }
                    }
                    .disabled(auth.isBusy || email.isEmpty)
                    .accessibilityIdentifier("nara.auth.forgot")
                }
            }
        }
        .frame(maxWidth: 520)
    }

    private var emailField: some View {
        TextField("Email", text: $email)
            .textFieldStyle(.plain)
            .font(StrandFont.body)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            #endif
            .focused($focus, equals: .email)
            .padding(12)
            .background(NoopPanelSurface(cornerRadius: 10))
            .accessibilityIdentifier("nara.auth.email")
    }

    private func passwordField(title: LocalizedStringKey, text: Binding<String>, field: Field,
                               isNew: Bool) -> some View {
        SecureField(title, text: text)
            .textFieldStyle(.plain)
            .font(StrandFont.body)
            #if os(iOS)
            .textContentType(isNew ? .newPassword : .password)
            #endif
            .focused($focus, equals: field)
            .padding(12)
            .background(NoopPanelSurface(cornerRadius: 10))
            .accessibilityIdentifier(field == .newPassword ? "nara.auth.newPassword" : "nara.auth.password")
    }

    // MARK: Emailed code

    private func signupCodeCard(email pending: String) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Enter your code").font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("We sent a code to \(pending). It can take a minute to arrive; check spam if you don't see it.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                codeField

                messages

                NoopButton("Verify", systemImage: "checkmark.seal", kind: .primary, fullWidth: true) {
                    focus = nil
                    Task {
                        await auth.verifySignupCode(code)
                        if case .signedIn = auth.phase { code = ""; password = "" }
                    }
                }
                .disabled(auth.isBusy || code.count < 6)
                .accessibilityIdentifier("nara.auth.verify")

                resendRow

                NoopButton("Use a different email", kind: .tertiary, fullWidth: true) {
                    code = ""
                    auth.cancelPending()
                }
                .accessibilityIdentifier("nara.auth.cancel")
            }
        }
        .frame(maxWidth: 520)
    }

    /// The code box takes digits only, whatever is typed or pasted into it.
    private var digitsOnlyCode: Binding<String> {
        Binding(get: { code },
                set: { code = String($0.filter { $0.isASCII && $0.isNumber }.prefix(10)) })
    }

    private var codeField: some View {
        TextField("Code from your email", text: digitsOnlyCode)
            .textFieldStyle(.plain)
            .font(StrandFont.body)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            #endif
            .focused($focus, equals: .code)
            .padding(12)
            .background(NoopPanelSurface(cornerRadius: 10))
            .accessibilityIdentifier("nara.auth.code")
    }

    private var resendRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int((auth.resendAvailableAt?.timeIntervalSince(context.date) ?? 0).rounded(.up)))
            NoopButton(remaining > 0 ? "Resend code in \(remaining)s" : "Resend code",
                       systemImage: "arrow.clockwise", kind: .secondary, fullWidth: true) {
                Task { await auth.resendSignupCode() }
            }
            .disabled(auth.isBusy || remaining > 0)
        }
        .accessibilityIdentifier("nara.auth.resend")
    }

    private func recoveryCard(email pending: String) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reset your password").font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Enter the code we sent to \(pending) and choose a new password.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                codeField
                passwordField(title: "New password (8+ characters)", text: $newPassword,
                              field: .newPassword, isNew: true)

                messages

                NoopButton("Change password", systemImage: "key", kind: .primary, fullWidth: true) {
                    focus = nil
                    Task {
                        await auth.completePasswordReset(code: code, newPassword: newPassword)
                        if case .signedIn = auth.phase { code = ""; newPassword = "" }
                    }
                }
                .disabled(auth.isBusy || code.count < 6 || newPassword.isEmpty)
                .accessibilityIdentifier("nara.auth.reset")

                NoopButton("Cancel", kind: .tertiary, fullWidth: true) {
                    code = ""
                    newPassword = ""
                    auth.cancelPending()
                }
            }
        }
        .frame(maxWidth: 520)
    }

    // MARK: Setup choice

    private func setupChoiceCard(_ fresh: NaraAccount) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatePill("Email verified", tone: .positive)
                        Spacer()
                    }
                    Text("Set up your account").font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.top, 6)
                    Text("\(fresh.email ?? String(localized: "Your account")) is ready. New to Nara? Continue. If you used Nara before sign-ins existed, recover that account with your enrollment code to bring all of its data into this sign-in.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if showsRecoveryEntry {
                    enrollmentCodeField

                    messages

                    NoopButton("Recover account", systemImage: "arrow.uturn.backward.circle", kind: .primary,
                               fullWidth: true) {
                        focus = nil
                        Task {
                            await auth.recoverAccount(enrollmentCode: enrollmentCode)
                            if auth.failure == nil { enrollmentCode = "" }
                            if case .signedIn = auth.phase { password = "" }
                        }
                    }
                    .disabled(auth.isBusy || enrollmentCode.isEmpty)
                    .accessibilityIdentifier("nara.setup.recover")

                    NoopButton("Back", kind: .tertiary, fullWidth: true) {
                        focus = nil
                        enrollmentCode = ""
                        showsRecoveryEntry = false
                    }
                    .disabled(auth.isBusy)
                } else {
                    messages

                    NoopButton("Continue", systemImage: "arrow.right.circle", kind: .primary, fullWidth: true) {
                        password = ""
                        auth.continueAsNewAccount()
                    }
                    .disabled(auth.isBusy)
                    .accessibilityIdentifier("nara.setup.continue")

                    NoopButton("Recover account from enrollment code", systemImage: "key.horizontal",
                               kind: .secondary, fullWidth: true) {
                        showsRecoveryEntry = true
                        focus = .enrollmentCode
                    }
                    .disabled(auth.isBusy)
                    .accessibilityIdentifier("nara.setup.showRecover")
                }
            }
        }
        .frame(maxWidth: 520)
    }

    private var enrollmentCodeField: some View {
        TextField("NARA-XXXX-XXXX-XXXX-XXXX-XXXX", text: $enrollmentCode)
            .textFieldStyle(.plain)
            .font(StrandFont.mono)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.characters)
            .textContentType(.oneTimeCode)
            #endif
            .focused($focus, equals: .enrollmentCode)
            .padding(12)
            .background(NoopPanelSurface(cornerRadius: 10))
            .accessibilityIdentifier("nara.setup.enrollmentCode")
    }

    // MARK: Signed in

    @ViewBuilder
    private func signedInCards(_ signedIn: NaraAccount) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    statusPill
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Signed in as").strandOverline()
                    Text(signedIn.email ?? String(localized: "your account"))
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityIdentifier("nara.account.email")
                }
                statusDetail
                if let notice = auth.notice ?? account.notice {
                    Text(notice)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 520)

        if CloudPushSettings.isConfigured {
            StrandCard {
                VStack(alignment: .leading, spacing: 12) {
                    if CloudPushSettings.isUserSwitchable {
                        Toggle(isOn: Binding(get: { CloudPushSettings.isEnabled },
                                             set: { account.setUploadsEnabled($0) })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Sync with your account").font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text("Uploads your strap data so it can be scored.")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityIdentifier("nara.account.sync")
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Synced with your account").font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Your strap data is saved privately to this account and scored there.")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("nara.account.syncAutomatic")
                    }

                    if !account.ownsLocalHistory {
                        Text("This phone's saved history belongs to another Nara account. It is not uploaded and is never mixed into your data.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 520)
        }

        NoopButton("Sign out", systemImage: "rectangle.portrait.and.arrow.right", kind: .secondary,
                   fullWidth: true) {
            confirmSignOut = true
        }
        .frame(maxWidth: 520)
        .accessibilityIdentifier("nara.account.signOut")
    }

    @ViewBuilder
    private var statusPill: some View {
        switch account.bootstrap {
        case .idle, .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(StrandPalette.accent)
                Text("Linking this phone…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        case .ready:
            StatePill("Connected", tone: .positive)
        case .paused:
            StatePill("Sync off", tone: .neutral)
        case .retrying:
            StatePill("Retrying", tone: .warning)
        case .blocked:
            StatePill("Needs attention", tone: .critical)
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        switch account.bootstrap {
        case .retrying(let message):
            Text(message)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .blocked(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusCritical)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton("Set up this phone again", systemImage: "arrow.triangle.2.circlepath",
                           kind: .secondary, fullWidth: true) {
                    Task { await account.resetPhoneLink() }
                }
                .accessibilityIdentifier("nara.account.reset")
            }
        default:
            EmptyView()
        }
    }

    // MARK: Messages

    @ViewBuilder
    private var messages: some View {
        if let failure = auth.failure {
            Text(failure.errorDescription ?? "")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusCritical)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("nara.auth.error")
        } else if let notice = auth.notice ?? account.notice {
            Text(notice)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("nara.auth.notice")
        }
    }
}

// MARK: - Today banner

/// A one-line prompt on Today for a build that scores in the cloud: if nobody is signed in there is nothing
/// to show, so say why and where to go. Hidden once the account is linked and in a build with no cloud.
public struct NaraAccountBanner: View {
    @ObservedObject private var auth: NaraAuthService
    @ObservedObject private var account: NaraAccountController

    @MainActor
    public init() {
        _auth = ObservedObject(wrappedValue: NaraAuthService.shared)
        _account = ObservedObject(wrappedValue: NaraAccountController.shared)
    }

    public var body: some View {
        if let message { banner(message) }
    }

    private var message: (text: String, tone: StrandTone)? {
        guard CloudPushSettings.isConfigured, CloudPushSettings.isEnabled, auth.isAvailable else { return nil }
        switch auth.phase {
        case .restoring:
            return nil
        case .signedOut, .awaitingSignupCode, .awaitingRecoveryCode:
            return (String(localized: "Sign in to Nara to sync your strap data and see your scores."), .accent)
        case .choosingSetup:
            return (String(localized: "Finish setting up your Nara account."), .accent)
        case .signedIn:
            switch account.bootstrap {
            case .retrying(let text): return (text, .warning)
            case .blocked(let text): return (text, .critical)
            default: return nil
            }
        }
    }

    private func banner(_ message: (text: String, tone: StrandTone)) -> some View {
        NavigationLink {
            NaraAccountView()
        } label: {
            StrandCard(padding: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(message.tone.color)
                    Text(message.text)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nara.account.banner")
    }
}
