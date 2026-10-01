import Foundation

/// Build-time and user-overridable configuration for the hosted-compute ("cloud") path.
///
/// Values are baked into Info.plist from `Config/CloudPush.xcconfig` (which `#include?`s the
/// gitignored `Config/CloudPushSecrets.xcconfig`), exactly as the FRWHOOP fleet client does. A
/// clean checkout therefore resolves every key to an empty string, `isConfigured` is false, and
/// the app behaves as offline NOOP — no endpoint, no uploads.
public enum CloudPushSettings {
    public static let endpointInfoKey = "NOOPPushEndpoint"
    public static let fleetTokenInfoKey = "NOOPPushToken"
    public static let anonKeyInfoKey = "NOOPSupabaseAnonKey"
    public static let sourceRevisionInfoKey = "NOOPSourceRevision"
    public static let finalHostedComputeInfoKey = "NOOPFinalHostedCompute"

    /// User-facing opt-out / manual override. Absent means "follow the build".
    private static let enabledOverrideKey = "noop.cloud.enabled.override"
    private static let endpointOverrideKey = "noop.cloud.endpoint.override"

    public static func bundleString(_ key: String) -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Receiver base URL (`…/functions/v1/push`), or nil when this build carries no endpoint.
    ///
    /// xcconfig cannot contain a bare `//`, so secrets files write the scheme as `https:/$()/`.
    /// Normalise that back to `https://` here rather than asking ops to hand-edit the plist.
    public static var receiverURL: URL? {
        let override = UserDefaults.standard.string(forKey: endpointOverrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = override.isEmpty ? bundleString(endpointInfoKey) : override
        guard !raw.isEmpty else { return nil }
        let repaired = raw.replacingOccurrences(of: "https:/$()/", with: "https://")
            .replacingOccurrences(of: "http:/$()/", with: "http://")
        guard let url = URL(string: repaired), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// The fleet credential (`noop_…`), sent as `x-noop-fleet-token` on every receiver request and
    /// as the bearer for enrollment. It is an ingest credential, not a session: it is extractable
    /// from the app bundle by anyone holding the binary, which the consented-fleet model accepts.
    public static var fleetToken: String { bundleString(fleetTokenInfoKey) }

    /// Supabase anon key, used only for authenticated score reads (never for ingest).
    public static var anonKey: String { bundleString(anonKeyInfoKey) }

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
    /// Cloud mode is OPT-IN: a build that merely carries a receiver still uploads nothing until the
    /// user turns it on, so the existing offline behaviour is what a fresh install does. A build cut
    /// with `NOOPFinalHostedCompute = YES` is the exception — that build is hosted-compute-only and
    /// starts enabled. Either way, an unconfigured build can never be enabled: there is no receiver
    /// to point at, and the toggle is refused rather than silently accepted.
    public static var isEnabled: Bool {
        guard isConfigured else { return false }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: enabledOverrideKey) != nil {
            return defaults.bool(forKey: enabledOverrideKey)
        }
        return isHostedComputeBuild
    }

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

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledOverrideKey)
    }

    public static var isConfigured: Bool { receiverURL != nil && !fleetToken.isEmpty }

    /// Resolves a receiver route against the configured base, e.g. `enroll` -> `…/push/enroll`.
    public static func route(_ subpath: String) -> URL? {
        guard let base = receiverURL else { return nil }
        let trimmed = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return base }
        return base.appendingPathComponent(trimmed)
    }
}
