import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Seams

/// The two receiver calls the account layer makes. `CloudReceiverClient` is the production implementation;
/// tests substitute a scripted one.
protocol CloudInstallationProvisioning: Sendable {
    func provisionInstallation(accessToken: String, expectedOwnerId: String, sourceId: String,
                               platform: CloudProvisioningPlatform, appVersion: String,
                               currentToken: String?) async throws -> CloudInstallationGrant
    func confirmWearable(identity: CloudPushIdentity, provisionalExternalDeviceId: String,
                         serial: String) async throws -> String
}

extension CloudReceiverClient: CloudInstallationProvisioning {}

/// What the account layer needs from the cloud runtime.
protocol CloudRuntimeControlling: AnyObject, Sendable {
    var runningScope: CloudDataScope? { get }
    func start(identity: CloudPushIdentity, deviceId: String) throws
    func stop() async
    func setCredentialRejectionHandler(_ handler: (@Sendable (CloudDataScope, Int) -> Void)?)
}

extension CloudPushRuntime: CloudRuntimeControlling {}

// MARK: - Controller

/// Turns a verified Supabase session into a working cloud path, and tears it down again.
///
///     verified session ─► this phone's source id for THAT account ─► installation credential (server-minted,
///     bound to exactly (account, source), kept in the Keychain) ─► upload runtime for that account's scope
///
/// Everything is derived from the signed-in account and from nothing else: the account id comes from the
/// session, the source id is minted per account, the credential is requested with the session's access token
/// (the request carries no user id; the server reads it from the verified token), and the runtime is started
/// for the scope of the credential it was given. Signing out stops the runtime and removes the credential
/// before anything else can sign in; the account's queued data stays in the journal under its own scope.
///
/// Level-triggered: every input (a session change, a rejected credential, a foreground, a retry timer) just
/// asks for a reconcile, and one serialized pass makes the world match the current session. Passes never
/// overlap and a request that arrives during a pass triggers exactly one more.
@MainActor
public final class NaraAccountController: ObservableObject {

    public enum Bootstrap: Equatable {
        /// Nobody is signed in (or this build has no account service).
        case idle
        /// Linking this phone to the account.
        case working
        /// The account is linked and the upload runtime is running.
        case ready
        /// The person turned cloud sync off. Nothing is uploaded and nothing new is queued.
        case paused
        /// A temporary problem; Nara retries by itself.
        case retrying(String)
        /// Needs the person: the message says what to do.
        case blocked(String)
    }

    @Published public private(set) var bootstrap: Bootstrap = .idle
    /// False when the signed-in account is not the one the on-device history belongs to.
    @Published public private(set) var ownsLocalHistory = true
    /// Why the last forced sign-out happened, for the sign-in screen.
    @Published public private(set) var notice: String?

    /// The controller the app uses.
    public static let shared = NaraAccountController(auth: NaraAuthService.shared)

    // Collaborators
    private let auth: NaraAuthService
    private let provisioner: any CloudInstallationProvisioning
    private let runtime: any CloudRuntimeControlling
    private let store: CloudPushIdentityStore
    private let defaults: UserDefaults
    /// `confirmWearableIfNeeded`'s request in flight, its next allowed attempt and its failures in a row, per
    /// (account, source, strap). In memory: a relaunch may ask again at once.
    private var wearableConfirmInFlight: [String: Task<Bool, Never>] = [:]
    private var wearableConfirmRetryAt: [String: Date] = [:]
    private var wearableConfirmFailures: [String: Int] = [:]
    private let appVersion: String
    private let isConfigured: () -> Bool
    private let uploadsEnabled: () -> Bool
    private let setUploadsFlag: (Bool) -> Void
    private let protectedDataAvailable: @MainActor () -> Bool
    private let now: () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void

    /// The local device id new records default to. Supplied by the app model once it exists.
    public var deviceIdProvider: @MainActor () -> String = { "my-whoop" }
    /// Called after the account is linked and the runtime is up (confirm the wearable, seed history, ...).
    public var onReady: (@MainActor (CloudPushIdentity) async -> Void)?
    /// Called after the account's runtime was stopped (cancel account-bound work).
    public var onAccountEnded: (@MainActor () async -> Void)?

    private var phaseSubscription: AnyCancellable?
    private var lastPhase: NaraAuthService.Phase = .restoring
    private var reconcileTask: Task<Void, Never>?
    private var needsAnotherPass = false
    private var forceRotation = false
    private var retryTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var consecutiveRejections = 0
    private var lastRejectionAt: Date?
    private var started = false
    private var signOutInFlight = false

    init(auth: NaraAuthService,
         provisioner: any CloudInstallationProvisioning = CloudReceiverClient(),
         runtime: any CloudRuntimeControlling = CloudPushRuntime.shared,
         store: CloudPushIdentityStore = .shared,
         defaults: UserDefaults = .standard,
         appVersion: String = NaraAccountController.bundleVersion(),
         isConfigured: @escaping () -> Bool = { CloudPushSettings.isConfigured },
         uploadsEnabled: @escaping () -> Bool = { CloudPushSettings.isEnabled },
         setUploadsFlag: @escaping (Bool) -> Void = { CloudPushSettings.setEnabled($0) },
         protectedDataAvailable: @escaping @MainActor () -> Bool = NaraAccountController.systemProtectedDataAvailable,
         now: @escaping () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }) {
        self.auth = auth
        self.provisioner = provisioner
        self.runtime = runtime
        self.store = store
        self.defaults = defaults
        self.appVersion = appVersion
        self.isConfigured = isConfigured
        self.uploadsEnabled = uploadsEnabled
        self.setUploadsFlag = setUploadsFlag
        self.protectedDataAvailable = protectedDataAvailable
        self.now = now
        self.sleep = sleep
    }

    // MARK: lifecycle

    /// Restore the session, then keep the cloud path in step with it. Idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        runtime.setCredentialRejectionHandler { [weak self] scope, status in
            Task { @MainActor in self?.credentialRejected(scope: scope, status: status) }
        }
        phaseSubscription = auth.$phase.sink { [weak self] phase in
            Task { @MainActor in self?.phaseChanged(to: phase) }
        }
        await auth.start()
        // The phase subscription above hops to the main actor before it reconciles, so on its own it can still be
        // in flight when this returns. Reconciling here makes "started" mean "the restored session has been acted on".
        requestReconcile()
        await settle()
    }

    /// Ask for a reconcile pass (a foreground, a retry). Cheap when nothing needs doing.
    public func refresh() {
        requestReconcile()
    }

    /// Wait for the pass in flight (and any it queued) to finish.
    public func settle() async {
        while let task = reconcileTask { await task.value }
    }

    private func phaseChanged(to phase: NaraAuthService.Phase) {
        let previous = lastPhase
        lastPhase = phase
        // Signing in or signing up is the person's own decision to use a cloud account, so it turns the
        // upload path on. A session that is merely restored at launch leaves their setting alone.
        if case .signedIn = phase {
            switch previous {
            case .signedOut, .awaitingSignupCode, .awaitingRecoveryCode, .choosingSetup:
                setUploadsFlag(true)
                notice = nil
            default:
                break
            }
        }
        requestReconcile()
    }

    private func requestReconcile(force: Bool = false) {
        if force { forceRotation = true }
        if reconcileTask != nil {
            needsAnotherPass = true
            return
        }
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.needsAnotherPass = false
                await self.reconcileOnce()
            } while self.needsAnotherPass
            self.reconcileTask = nil
        }
    }

    // MARK: the pass

    private func reconcileOnce() async {
        guard !signOutInFlight else { return }
        guard isConfigured() else {
            bootstrap = .idle
            return
        }
        switch auth.phase {
        case .restoring:
            return
        case .signedIn(let account):
            await bind(account)
        case .signedOut, .awaitingSignupCode, .awaitingRecoveryCode, .choosingSetup:
            // A new account that has not chosen between starting fresh and recovering is not linked yet:
            // claiming the history or provisioning now would make it ineligible for recovery.
            await unbind()
        }
    }

    private func bind(_ account: NaraAccount) async {
        let owner = account.userId
        if let running = runtime.runningScope, running.ownerId != owner {
            // Another account was running and the session moved on without a sign-out. Retire it fully.
            store.removeCredential(forOwner: running.ownerId)
            await teardownRuntime()
        }
        retryTask?.cancel()
        store.activate(ownerId: owner)
        ownsLocalHistory = CloudLocalDataBinding.claimIfUnclaimed(by: owner, defaults: defaults)
        guard uploadsEnabled() else {
            await teardownRuntime()
            bootstrap = .paused
            return
        }
        let alreadyReady: Bool = {
            guard bootstrap == .ready, let scope = runtime.runningScope else { return false }
            return scope.ownerId == owner
        }()
        if !alreadyReady { bootstrap = .working }

        let force = forceRotation
        forceRotation = false
        do {
            let identity = try await ensureIdentity(for: account, force: force)
            // The session may have changed while the network call was in flight.
            guard case .signedIn(let current) = auth.phase, current.userId == owner else {
                requestReconcile()
                return
            }
            try runtime.start(identity: identity, deviceId: deviceIdProvider())
            consecutiveFailures = 0
            bootstrap = .ready
            await onReady?(identity)
        } catch {
            await handleFailure(error, account: account)
        }
    }

    private func unbind() async {
        retryTask?.cancel()
        retryTask = nil
        // Before the first unlock after a reboot the Keychain is unreadable, so "no session" there means
        // "can't tell yet", not "signed out". Leave the credential alone and look again once data is available.
        guard protectedDataAvailable() else {
            scheduleRetry(after: 15)
            return
        }
        if let owner = store.currentOwnerId() {
            // Clear the pointer and the credential first: nothing may restart this account's upload path
            // while the runtime is still winding down.
            store.removeCredential(forOwner: owner)
            store.signOutCurrentOwner()
            RawDataSessionStore.clearPersistedCaptureIntent()
        }
        await teardownRuntime()
        ownsLocalHistory = true
        consecutiveFailures = 0
        consecutiveRejections = 0
        bootstrap = .idle
    }

    private func teardownRuntime() async {
        guard runtime.runningScope != nil else { return }
        await runtime.stop()
        await onAccountEnded?()
    }

    // MARK: credential

    /// How far ahead of expiry a credential is refreshed. The server rotates a credential that is within 30
    /// days of expiring, so asking inside that window gets a fresh one and asking outside it is a no-op.
    static let refreshWindow: TimeInterval = 30 * 24 * 3600

    private func ensureIdentity(for account: NaraAccount, force: Bool) async throws -> CloudPushIdentity {
        let owner = account.userId
        var attempts = 0
        while true {
            attempts += 1
            let source = store.sourceId(forOwner: owner)
            let existing = store.identity(forOwner: owner)
            if !force, let existing, existing.provisioning == .supabaseAuth, !expiresSoon(owner: owner) {
                return existing
            }
            do {
                let accessToken = try await auth.accessToken()
                let grant = try await provisioner.provisionInstallation(
                    accessToken: accessToken, expectedOwnerId: owner, sourceId: source,
                    platform: .current, appVersion: appVersion, currentToken: existing?.uploadToken)
                guard grant.userId == owner, grant.sourceId == source else {
                    throw CloudReceiverError.ownershipMismatch
                }
                if let token = grant.installationToken {
                    store.store(token: token, tokenId: grant.tokenId, expiresAt: grant.expiresAt,
                                ownerId: owner, sourceId: source)
                    guard let stored = store.identity(forOwner: owner), stored.uploadToken == token else {
                        // The Keychain did not keep it. The server holds only a hash, so the next pass mints a
                        // new one; do not pretend this one is usable.
                        throw NaraAccountError.credentialNotPersisted
                    }
                    return stored
                }
                // `reused`: the credential we presented is still good; only its expiry is refreshed.
                guard let existing else { throw CloudReceiverError.malformedResponse }
                store.store(token: existing.uploadToken, tokenId: grant.tokenId, expiresAt: grant.expiresAt,
                            ownerId: owner, sourceId: source)
                return store.identity(forOwner: owner) ?? existing
            } catch CloudReceiverError.installationUnavailable where attempts < 3,
                    CloudReceiverError.installationRetired where attempts < 3 {
                // This source id can not be used by this account (it is taken, or was closed). Abandon it —
                // never re-bind it — and register this phone again under a fresh one.
                store.rotateSourceId(forOwner: owner)
                continue
            }
        }
    }

    private func expiresSoon(owner: String) -> Bool {
        guard let expiry = store.credentialExpiry(forOwner: owner) else { return false }
        return expiry.timeIntervalSince(now()) < Self.refreshWindow
    }

    // MARK: failures

    private func handleFailure(_ error: Error, account: NaraAccount) async {
        if let authError = error as? NaraAuthError {
            switch authError {
            case .network, .rateLimited, .other:
                transientFailure(String(localized: "Couldn't reach Nara. We'll keep trying."), retryAfter: nil)
            case .sessionEnded, .notSignedIn:
                // The service already ended the session; the phase change drives the teardown.
                break
            default:
                transientFailure(authError.errorDescription ?? "", retryAfter: nil)
            }
            return
        }
        guard let receiver = error as? CloudReceiverError else {
            if error is NaraAccountError {
                transientFailure(String(localized: "Couldn't save this phone's access securely. We'll try again."),
                                 retryAfter: nil)
            } else {
                transientFailure(String(localized: "Couldn't finish linking this phone. We'll keep trying."),
                                 retryAfter: nil)
            }
            return
        }
        switch receiver {
        case .sessionRejected, .emailNotConfirmed, .accountRetired:
            // The server does not accept this account any more. Stop everything and sign out.
            notice = receiver.errorDescription
            await auth.signOut()
            requestReconcile()
        case .installationRevoked:
            await stopForBlock()
            bootstrap = .blocked(String(localized: "This phone's access to your account was revoked. Reset this phone's link to set it up again."))
        case .installationLimit:
            await stopForBlock()
            bootstrap = .blocked(receiver.errorDescription ?? "")
        case .notConfigured:
            bootstrap = .idle
        case .ownershipMismatch, .malformedResponse, .unsupportedVersion, .rejected, .credentialRejected,
             .installationUnavailable, .installationRetired, .notSignedIn, .recoveryCodeInvalid,
             .recoveryAlreadyUsed, .recoveryAccountActive, .recoveryAccountNotEmpty:
            await stopForBlock()
            bootstrap = .blocked(receiver.errorDescription ?? "")
        case .rateLimited(let retryAfter):
            transientFailure(receiver.errorDescription ?? "", retryAfter: retryAfter)
        case .serverFault, .transport:
            transientFailure(receiver.errorDescription ?? "", retryAfter: nil)
        }
    }

    /// Stop uploading for a condition that will not fix itself. The account's queued data stays put.
    private func stopForBlock() async {
        await teardownRuntime()
    }

    private func transientFailure(_ message: String, retryAfter: TimeInterval?) {
        consecutiveFailures += 1
        bootstrap = .retrying(message)
        let backoff = min(300, 5 * pow(2, Double(min(consecutiveFailures, 6))))
        scheduleRetry(after: max(retryAfter ?? 0, backoff))
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        let sleep = self.sleep
        retryTask = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            self?.requestReconcile()
        }
    }

    // MARK: rejected credential

    /// The receiver refused the running account's credential. Ask for a replacement, but never in a tight loop:
    /// each unsuccessful round doubles the wait (two minutes up to half an hour), so a credential that can not
    /// be cured does not spend the account's provisioning allowance.
    func credentialRejected(scope: CloudDataScope, status: Int) {
        guard runtime.runningScope == scope, case .signedIn(let account) = auth.phase,
              account.userId == scope.ownerId else { return }
        let wait = min(1800, 120 * pow(2, Double(min(consecutiveRejections, 4))))
        if let last = lastRejectionAt, now().timeIntervalSince(last) < wait { return }
        lastRejectionAt = now()
        consecutiveRejections += 1
        requestReconcile(force: true)
    }

    // MARK: wearable link

    /// Link this phone's provisional strap id to the strap's real serial on the server, once per
    /// (account, source, provisional id, serial). The server binds the canonical device to this account, and
    /// refuses to move it to another.
    @discardableResult
    public func confirmWearableIfNeeded(provisionalDeviceId: String, serial: String) async -> Bool {
        guard case .signedIn(let account) = auth.phase,
              let identity = store.identity(forOwner: account.userId),
              runtime.runningScope == identity.scope, !serial.isEmpty else { return false }
        let key = Self.wearableKey(scope: identity.scope)
        let value = "\(provisionalDeviceId.lowercased())|\(serial)"
        if defaults.string(forKey: key) == value { return true }
        // One confirm at a time, and none again soon after one failed. Every foreground runs this from two paths
        // (the scene becoming active and the account reconcile it starts), and the strap's serial being read
        // runs it again; failed confirms then went out in pairs a tenth of a second apart. The server answers a
        // busy confirm with a 503 and locks both devices' inputs while it checks, which turned away the uploads
        // arriving meanwhile with 503s of their own.
        let attempt = "\(key)|\(value)"
        if let running = wearableConfirmInFlight[attempt] { return await running.value }
        if let notBefore = wearableConfirmRetryAt[attempt], Date() < notBefore { return false }
        let shared = Task { @MainActor [weak self, provisioner] () -> Bool in
            let outcome: Result<Void, Error>
            do {
                _ = try await provisioner.confirmWearable(identity: identity,
                                                          provisionalExternalDeviceId: provisionalDeviceId,
                                                          serial: serial)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return false }
            self.wearableConfirmInFlight[attempt] = nil
            switch outcome {
            case .success:
                self.defaults.set(value, forKey: key)
                self.wearableConfirmRetryAt[attempt] = nil
                self.wearableConfirmFailures[attempt] = nil
                return true
            case .failure(let error):
                let failures = (self.wearableConfirmFailures[attempt] ?? 0) + 1
                self.wearableConfirmFailures[attempt] = failures
                self.wearableConfirmRetryAt[attempt] = Date().addingTimeInterval(
                    Self.wearableConfirmBackoff(failures: failures, error: error))
                if let receiverError = error as? CloudReceiverError, receiverError == .credentialRejected {
                    self.credentialRejected(scope: identity.scope, status: 401)
                }
                return false
            }
        }
        wearableConfirmInFlight[attempt] = shared
        return await shared.value
    }

    /// How long to wait after the `failures`-th failed confirm in a row: a minute, doubling to half an hour, or
    /// what the server asked for when it rate-limited.
    static func wearableConfirmBackoff(failures: Int, error: Error) -> TimeInterval {
        if let receiverError = error as? CloudReceiverError, case .rateLimited(let retryAfter?) = receiverError {
            return max(retryAfter, 60)
        }
        return min(60 * pow(2, Double(max(0, failures - 1))), 1_800)
    }

    static func wearableKey(scope: CloudDataScope) -> String {
        "noop.cloud.wearableConfirmed.v2.\(scope.ownerId).\(scope.sourceId)"
    }

    // MARK: user actions

    /// End the session. The upload path comes down first: the credential is removed and the runtime stopped
    /// while the account is still the signed-in one, so nothing the next sign-in does can meet it half-closed.
    /// The account's queued data stays in the journal under its own scope.
    public func signOut() async {
        signOutInFlight = true
        await settle()
        if let owner = runtime.runningScope?.ownerId { store.removeCredential(forOwner: owner) }
        store.signOutCurrentOwner()
        // A signed-out install must not re-arm raw-IMU capture on the next connect.
        RawDataSessionStore.clearPersistedCaptureIntent()
        await teardownRuntime()
        await auth.signOut()
        signOutInFlight = false
        requestReconcile()
        await settle()
    }

    /// Give this phone a brand-new identity on the account: abandon the current source id (the old one and
    /// anything stamped with it stay where they are) and register again. For a link the server revoked.
    public func resetPhoneLink() async {
        guard case .signedIn(let account) = auth.phase else { return }
        await teardownRuntime()
        store.rotateSourceId(forOwner: account.userId)
        consecutiveFailures = 0
        requestReconcile()
        await settle()
    }

    /// The upload switch in the account screen.
    public func setUploadsEnabled(_ enabled: Bool) {
        setUploadsFlag(enabled)
        objectWillChange.send()
        requestReconcile()
    }

    // MARK: environment

    nonisolated static func bundleVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "0"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        let version = "\(short) (\(build))"
        return version.count <= 64 ? version : String(version.prefix(64))
    }

    @MainActor static func systemProtectedDataAvailable() -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        return UIApplication.shared.isProtectedDataAvailable
        #else
        return true
        #endif
    }
}

enum NaraAccountError: Error, Equatable {
    /// The Keychain did not keep a freshly minted credential.
    case credentialNotPersisted
}
