import Foundation

/// Build-time and user-overridable configuration for the hosted-compute ("cloud") path.
///
/// Values are baked into Info.plist from `Config/CloudPush.xcconfig` (which `#include?`s the
/// gitignored `Config/CloudPushSecrets.xcconfig`). A clean checkout therefore resolves every key to an
/// empty string, `isConfigured` is false, and the app behaves as offline NOOP: no endpoint, no sign-in,
/// no uploads.
///
/// The build carries exactly two cloud facts: where the receiver lives and the project's Supabase
/// PUBLISHABLE key. Neither identifies a user. A tester authenticates with Supabase Auth, and the app then
/// provisions its own per-account installation credential from that verified session; nothing shared is
/// needed to upload. The legacy shared fleet token only exists for an explicit migration build
/// (`NOOPAllowLegacyEnrollment`), and every accessor for it returns empty otherwise.
public enum CloudPushSettings {
    public static let endpointInfoKey = "NOOPPushEndpoint"
    public static let publishableKeyInfoKey = "NOOPSupabasePublishableKey"
    /// Deprecated legacy anon JWT, honoured only as a fallback for the publishable key.
    public static let anonKeyInfoKey = "NOOPSupabaseAnonKey"
    public static let allowLegacyEnrollmentInfoKey = "NOOPAllowLegacyEnrollment"
    public static let legacyFleetTokenInfoKey = "NOOPLegacyFleetToken"
    public static let sourceRevisionInfoKey = "NOOPSourceRevision"
    public static let finalHostedComputeInfoKey = "NOOPFinalHostedCompute"

    /// User-facing opt-out / manual override. Absent means "follow the build".
    private static let enabledOverrideKey = "noop.cloud.enabled.override"
    private static let endpointOverrideKey = "noop.cloud.endpoint.override"

    /// Test seam: lets a test supply Info.plist values without a bundle. Nil in production.
    nonisolated(unsafe) static var bundleStringOverride: (@Sendable (String) -> String?)?

    public static func bundleString(_ key: String) -> String {
        if let override = bundleStringOverride, let value = override(key) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Receiver base URL (`…/functions/v1/push`), or nil when this build carries no endpoint.
    ///
    /// xcconfig cannot contain a bare `//`, so secrets files write the scheme as `https:/$()/`.
    /// Normalise that back to `https://` here rather than asking ops to hand-edit the plist.
    ///
    /// A hosted-compute build always talks to the endpoint it was cut with: the developer override is
    /// ignored there, so no stale preference can point a customer's data at another server.
    public static var receiverURL: URL? {
        let override = isHostedComputeBuild
            ? ""
            : (UserDefaults.standard.string(forKey: endpointOverrideKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let raw = override.isEmpty ? bundleString(endpointInfoKey) : override
        guard !raw.isEmpty else { return nil }
        let repaired = raw.replacingOccurrences(of: "https:/$()/", with: "https://")
            .replacingOccurrences(of: "http:/$()/", with: "http://")
        guard let url = URL(string: repaired), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// The Supabase publishable key (`sb_publishable_…`) used as the `apikey` on Auth requests.
    ///
    /// Public by design, but it must still be the PUBLISHABLE key: a Supabase secret / service-role key
    /// is refused here so a misconfigured build cannot ship one inside the app.
    public static var publishableKey: String {
        let configured = bundleString(publishableKeyInfoKey)
        let candidate = configured.isEmpty ? bundleString(anonKeyInfoKey) : configured
        return isForbiddenServerKey(candidate) ? "" : candidate
    }

    /// True for key shapes that grant server-side privileges and must never be embedded in an app.
    static func isForbiddenServerKey(_ key: String) -> Bool {
        if key.hasPrefix("sb_secret_") { return true }
        // A legacy service_role JWT carries `"role":"service_role"` in its payload.
        let parts = key.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let role = object["role"] as? String else { return false }
        return role == "service_role"
    }

    /// Whether this build may keep using a pre-Auth NARA enrollment credential already stored on the phone.
    /// Off for every tester build, and there is no way to redeem a new code.
    public static var allowLegacyEnrollment: Bool {
        let raw = bundleString(allowLegacyEnrollmentInfoKey).lowercased()
        return raw == "true" || raw == "yes" || raw == "1"
    }

    /// The legacy shared fleet credential. Empty unless the build explicitly allows legacy enrollment, so
    /// a stray value in a local secrets file can never put a shared token on the wire.
    public static var fleetToken: String {
        allowLegacyEnrollment ? bundleString(legacyFleetTokenInfoKey) : ""
    }

    public static var sourceRevision: String {
        let v = bundleString(sourceRevisionInfoKey)
        return v.isEmpty ? "development" : v
    }

    /// True when the build was cut for hosted compute. Hosted builds have no local scoring.
    public static var isHostedComputeBuild: Bool {
        let raw = bundleString(finalHostedComputeInfoKey).lowercased()
        return raw == "true" || raw == "yes" || raw == "1"
    }

    /// Master switch.
    ///
    /// A build cut with `NOOPFinalHostedCompute = YES` is hosted-compute-only: it has no local scoring and
    /// no offline mode, so cloud is not a preference there. It is on whenever the build is configured, and
    /// neither a stored override nor `setEnabled(_:)` can turn it off.
    ///
    /// Any other build keeps cloud OPT-IN: carrying a receiver is not consent to upload, so nothing leaves
    /// the phone until the user turns it on. An unconfigured build can never be enabled: there is no
    /// receiver to point at, and the toggle is refused rather than silently accepted.
    ///
    /// Enabled does not mean uploading: nothing leaves the phone until an account is signed in and has an
    /// installation credential (see `CloudPushIdentityStore.current()`).
    public static var isEnabled: Bool {
        guard isConfigured else { return false }
        if isHostedComputeBuild { return true }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: enabledOverrideKey) != nil {
            return defaults.bool(forKey: enabledOverrideKey)
        }
        return false
    }

    /// Whether the person can choose to switch cloud sync on or off. False in a hosted-compute build,
    /// where there is nothing to switch to, so screens show the state instead of offering a control.
    public static var isUserSwitchable: Bool { isConfigured && !isHostedComputeBuild }

    /// The receiver's project origin (`https://<project>.supabase.co`), derived from the configured
    /// receiver URL by dropping the function path.
    ///
    /// The durability receipt binds an owner through an `AccountScope`, whose project URL must be the
    /// canonical origin rather than the function endpoint, so the receipt check needs this form. It
    /// returns an empty string when no receiver is configured.
    public static var canonicalProjectURL: String {
        guard let url = receiverURL, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ""
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }

    /// The Supabase Auth base (`<origin>/auth/v1`), or nil when no receiver is configured.
    public static var authURL: URL? {
        let origin = canonicalProjectURL
        guard !origin.isEmpty else { return nil }
        return URL(string: origin)?.appendingPathComponent("auth").appendingPathComponent("v1")
    }

    public static func setEnabled(_ enabled: Bool) {
        guard !isHostedComputeBuild else {
            // Cloud cannot be turned off here; a request to do so only makes sure it is running.
            Task { CloudPushRuntime.shared.startIfEnabled() }
            return
        }
        UserDefaults.standard.set(enabled, forKey: enabledOverrideKey)
        // The master switch is a lifecycle control, not just a flag. Flipping it off must stop the
        // runtime's capture staging AND its upload cycle the moment the user asks (D1): the durable
        // journal and any already-sealed batches are retained and resume on re-enable, so nothing is
        // deleted or uploaded while cloud is off. Flipping it on resumes an enrolled install. Both
        // calls are idempotent and a no-op when the runtime is already in the target state, and the
        // runtime paths additionally gate on `isEnabled` so there is no window between the flag flip
        // and the runtime reacting.
        if enabled {
            Task { CloudPushRuntime.shared.startIfEnabled() }
        } else {
            Task { await CloudPushRuntime.shared.stop() }
        }
    }

    /// A build is configured once it knows where the receiver is and which project's Auth to talk to.
    public static var isConfigured: Bool { receiverURL != nil && !publishableKey.isEmpty }

    /// Resolves a receiver route against the configured base, e.g. `enroll` -> `…/push/enroll`.
    public static func route(_ subpath: String) -> URL? {
        guard let base = receiverURL else { return nil }
        let trimmed = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return base }
        return base.appendingPathComponent(trimmed)
    }
}
