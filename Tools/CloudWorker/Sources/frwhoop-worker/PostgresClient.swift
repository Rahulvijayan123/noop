import Foundation
import CLibPQ

/// Error classification. Lanes use it to pick a settlement policy:
///   - `connectionLost`  the client cannot talk to the server (retry after a
///                       reconnect at a safe transaction boundary);
///   - `serialization`   a concurrent transaction won the race (retry, jittered);
///   - `aborted`         the transaction is already aborted, so nothing else may
///                       run inside it (roll back, then settle in a new tx);
///   - `stale`           the fenced lease/revision moved on (never retry the same
///                       claim: the queue already owns the newer work);
///   - `deterministic`   the input violates a contract, so a retry cannot help
///                       (bounded, next-eligible, quarantine).
enum PGErrorKind: String {
    case connectionLost = "connection_lost"
    case serialization = "serialization"
    case aborted = "aborted_transaction"
    case stale = "stale_lease"
    case deterministic = "deterministic"
    case other = "other"
}

/// Connection options. Built from the environment, so no secret is compiled in.
///
/// F6: the worker carries the ingest secret and the database password across the
/// public internet, so TLS is mandatory by default. The connection is opened with
/// `sslmode=verify-full` (host name AND certificate chain checked) against the
/// project CA, and the process refuses to run if the negotiated session turns out
/// to be plaintext. `FRWHOOP_ALLOW_INSECURE_DB=1` is the only way to relax this,
/// and it is intended for local development only.
struct PostgresOptions {
    var connectionString: String
    var sslMode: String
    var sslRootCert: String?
    var applicationName: String
    var allowInsecure: Bool
    var connectTimeoutSeconds: Int
    var reconnectDeadlineSeconds: Double
    var statementTimeoutMS: Int
    var idleTransactionTimeoutMS: Int

    /// CA locations searched, in order, when `FRWHOOP_DB_SSLROOTCERT` is unset.
    static let defaultCARootCertPaths = [
        "/etc/frwhoop/supabase-ca.pem",
        "/etc/frwhoop/supabase-ca-chain.pem",
        "deploy/supabase-ca-chain.pem",
        "/opt/noop/deploy/supabase-ca-chain.pem",
    ]

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> PostgresOptions {
        guard let raw = env["FRWHOOP_DB_URL"], !raw.isEmpty else {
            throw PostgresClient.Error(message: "FRWHOOP_DB_URL is required", sqlstate: nil, kind: .other)
        }
        let allowInsecure = (env["FRWHOOP_ALLOW_INSECURE_DB"] ?? "") == "1"
        var mode = env["FRWHOOP_DB_SSLMODE"] ?? "verify-full"
        if !allowInsecure && mode != "verify-full" && mode != "verify-ca" {
            throw PostgresClient.Error(
                message: "refusing to start: FRWHOOP_DB_SSLMODE=\(mode) does not authenticate the server. "
                    + "Use verify-full (default) or verify-ca, or set FRWHOOP_ALLOW_INSECURE_DB=1 for local development only.",
                sqlstate: nil, kind: .other)
        }
        var caPath = env["FRWHOOP_DB_SSLROOTCERT"].flatMap { $0.isEmpty ? nil : $0 }
        if caPath == nil {
            caPath = defaultCARootCertPaths.first { FileManager.default.fileExists(atPath: $0) }
        }
        return PostgresOptions(
            connectionString: raw,
            sslMode: mode,
            sslRootCert: caPath,
            applicationName: env["FRWHOOP_WORKER_NAME"].map { "frwhoop-worker:\($0)" } ?? "frwhoop-worker",
            allowInsecure: allowInsecure,
            connectTimeoutSeconds: Int(env["FRWHOOP_DB_CONNECT_TIMEOUT_S"] ?? "10") ?? 10,
            reconnectDeadlineSeconds: Double(Int(env["FRWHOOP_DB_RECONNECT_DEADLINE_MS"] ?? "60000") ?? 60000) / 1000.0,
            statementTimeoutMS: Int(env["FRWHOOP_DB_STATEMENT_TIMEOUT_MS"] ?? "120000") ?? 120000,
            idleTransactionTimeoutMS: Int(env["FRWHOOP_DB_IDLE_TX_TIMEOUT_MS"] ?? "120000") ?? 120000)
    }
}

/// A single Postgres connection over libpq with JSON-value helpers.
///
/// The worker connects with its own Postgres credentials (never the service-role
/// HTTP key) and calls the SECURITY DEFINER work-queue functions directly. A
/// transaction-scoped `request.jwt.claims` GUC is set where a queue function
/// checks `auth.role()`; the claim never leaves the current transaction.
///
/// F6: a dead TCP connection is recovered by re-dialling with a capped
/// exponential backoff, re-applying the session settings and re-asserting TLS.
/// Recovery only ever happens at a safe transaction boundary: `reconnect()` refuses
/// to run while a transaction is open, and the transaction helpers call
/// `ensureConnected()` *before* `BEGIN`. When the outage outlives the reconnect
/// deadline the error surfaces as `.connectionLost`, which `main` turns into a
/// non-zero exit so systemd restarts the process.
final class PostgresClient {
    struct Error: Swift.Error, CustomStringConvertible {
        let message: String
        let sqlstate: String?
        let kind: PGErrorKind

        init(message: String, sqlstate: String?, kind: PGErrorKind) {
            self.message = message
            self.sqlstate = sqlstate
            self.kind = kind
        }

        var description: String {
            var s = message
            if let sqlstate { s += " [sqlstate=\(sqlstate), kind=\(kind.rawValue)]" }
            else { s += " [kind=\(kind.rawValue)]" }
            return s
        }
    }

    private var conn: OpaquePointer?
    private let options: PostgresOptions
    private let parameters: [(String, String)]
    private var txDepth = 0
    private var reconnectInProgress = false

    /// Observability for the heartbeat.
    private(set) var reconnectCount = 0
    private(set) var connectedSince: Date?
    private(set) var lastReconnectError: String?

    convenience init(connectionString: String) throws {
        try self.init(options: PostgresOptions(
            connectionString: connectionString,
            sslMode: "verify-full",
            sslRootCert: PostgresOptions.defaultCARootCertPaths.first { FileManager.default.fileExists(atPath: $0) },
            applicationName: "frwhoop-worker",
            allowInsecure: false,
            connectTimeoutSeconds: 10,
            reconnectDeadlineSeconds: 60,
            statementTimeoutMS: 120_000,
            idleTransactionTimeoutMS: 120_000))
    }

    init(options: PostgresOptions) throws {
        self.options = options
        self.parameters = try PostgresClient.resolvedParameters(options)
        try openInitial()
    }

    deinit {
        if let conn { PQfinish(conn) }
    }

    // MARK: - Connection lifecycle

    private func openInitial() throws {
        guard let newConn = PostgresClient.dial(parameters) else {
            throw Error(message: "postgres connect failed: libpq allocation failure", sqlstate: nil, kind: .connectionLost)
        }
        guard PQstatus(newConn) == CONNECTION_OK else {
            let msg = String(cString: PQerrorMessage(newConn))
            PQfinish(newConn)
            throw Error(message: "postgres connect failed: \(msg)", sqlstate: nil, kind: .connectionLost)
        }
        conn = newConn
        connectedSince = Date()
        try applySessionSettings()
        try assertTLS()
    }

    var isConnected: Bool { conn != nil && PQstatus(conn) == CONNECTION_OK }
    var isInTransaction: Bool { txDepth > 0 }

    /// Reconnect when the connection is not usable. Cheap when healthy, so lanes
    /// call it once per cycle (a safe transaction boundary).
    func ensureConnected() throws {
        if isConnected { return }
        try reconnect()
    }

    /// Re-dial with a capped exponential backoff, then re-apply the session
    /// settings and re-assert TLS. Never runs while a transaction is open.
    func reconnect() throws {
        if txDepth > 0 {
            throw Error(message: "refusing to reconnect inside a transaction", sqlstate: nil, kind: .connectionLost)
        }
        if reconnectInProgress { return }
        reconnectInProgress = true
        defer { reconnectInProgress = false }

        let deadline = Date().addingTimeInterval(options.reconnectDeadlineSeconds)
        var delay = 1.0
        var attempt = 0
        var lastMessage = "no attempt made"
        while true {
            attempt += 1
            if let existing = conn { PQfinish(existing) }
            conn = nil
            connectedSince = nil

            if let newConn = PostgresClient.dial(parameters) {
                if PQstatus(newConn) == CONNECTION_OK {
                    conn = newConn
                    do {
                        try applySessionSettings()
                        try assertTLS()
                        connectedSince = Date()
                        reconnectCount += 1
                        lastReconnectError = nil
                        FileHandle.standardError.write(
                            "frwhoop-worker: db reconnected (attempt \(attempt), total \(reconnectCount))\n".data(using: .utf8)!)
                        return
                    } catch {
                        lastMessage = String(describing: error)
                        PQfinish(newConn)
                        conn = nil
                    }
                } else {
                    lastMessage = String(cString: PQerrorMessage(newConn))
                    PQfinish(newConn)
                    conn = nil
                }
            } else {
                lastMessage = "libpq allocation failure"
            }

            if Date() >= deadline {
                lastReconnectError = lastMessage
                throw Error(
                    message: "database unreachable: reconnect failed after \(attempt) attempt(s) in "
                        + "\(Int(options.reconnectDeadlineSeconds))s: \(lastMessage)",
                    sqlstate: nil, kind: .connectionLost)
            }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 2, 30)
        }
    }

    /// Apply the session settings that must survive a reconnect. Uses raw libpq
    /// so it cannot recurse through `ensureConnected`.
    private func applySessionSettings() throws {
        try execRaw("SET statement_timeout = '\(options.statementTimeoutMS)ms'")
        try execRaw("SET idle_in_transaction_session_timeout = '\(options.idleTransactionTimeoutMS)ms'")
        try execRaw("SET tcp_keepalives_idle = 60")
        try execRaw("SET tcp_keepalives_interval = 15")
        try execRaw("SET tcp_keepalives_count = 4")
    }

    /// Fail closed when the negotiated session is not actually encrypted.
    func assertTLS() throws {
        guard !options.allowInsecure else { return }
        let rows = try rawQuery("select coalesce((select ssl from pg_stat_ssl where pid = pg_backend_pid()), false)::text as tls")
        let value = rows.first?["tls"] ?? ""
        guard value == "true" else {
            throw Error(
                message: "refusing to run: the database session is NOT using TLS "
                    + "(pg_stat_ssl.ssl=\(value.isEmpty ? "unknown" : value)). "
                    + "Set FRWHOOP_DB_SSLMODE=verify-full and FRWHOOP_DB_SSLROOTCERT=<supabase CA pem>.",
                sqlstate: nil, kind: .connectionLost)
        }
    }

    /// Facts for the heartbeat: the backend pid, whether TLS is on, and the
    /// sslmode the worker demanded.
    func connectionFacts() -> [String: String] {
        var out: [String: String] = [
            "sslmode": options.sslMode,
            "sslrootcert": options.sslRootCert ?? "(system store)",
            "reconnects": String(reconnectCount),
            "insecure_override": options.allowInsecure ? "true" : "false",
        ]
        if let rows = try? rawQuery(
            "select pg_backend_pid()::text as pid, coalesce((select ssl from pg_stat_ssl where pid = pg_backend_pid()), false)::text as tls"),
            let row = rows.first {
            out["backend_pid"] = row["pid"]
            out["tls"] = row["tls"]
        }
        return out
    }

    // MARK: - Statements

    /// Run one statement; throw on non-OK command status.
    func exec(_ sql: String) throws {
        try runRaw(sql)
    }

    /// Isolation level for an explicitly driven transaction.
    enum Isolation {
        case readCommitted
        case repeatableRead

        var beginStatement: String {
            switch self {
            case .readCommitted: return "BEGIN"
            case .repeatableRead: return "BEGIN ISOLATION LEVEL REPEATABLE READ"
            }
        }
    }

    /// Begin a transaction, run `body`, and commit only if body returns normally.
    /// Nested begin is refused: lanes never overlap transactions on one connection.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try beginTransaction(.readCommitted)
        return try finishTransaction(body)
    }

    /// A REPEATABLE READ transaction: the fenced input snapshot the scoring
    /// lane requires (claim, seal, publish and finish must share one txid).
    func withRepeatableRead<T>(_ body: () throws -> T) throws -> T {
        try beginTransaction(.repeatableRead)
        return try finishTransaction(body)
    }

    /// Explicit transaction control. The scoring and archive lanes need to choose
    /// between commit and rollback *after* they have seen a fenced function's
    /// return value, so they drive the transaction themselves.
    func beginTransaction(_ isolation: Isolation = .readCommitted) throws {
        if txDepth > 0 { throw Error(message: "nested transaction refused", sqlstate: nil, kind: .other) }
        try ensureConnected()
        try runRaw(isolation.beginStatement)
        txDepth = 1
    }

    func commitTransaction() throws {
        guard txDepth > 0 else { return }
        do {
            try runRaw("COMMIT")
            txDepth = 0
        } catch {
            txDepth = 0
            throw error
        }
    }

    /// Roll back the current transaction. Tolerant: a no-op when no transaction
    /// is open, so a lane can call it from any `catch` without bookkeeping.
    func rollbackTransaction() {
        guard txDepth > 0 else { return }
        try? runRaw("ROLLBACK")
        txDepth = 0
    }

    private func finishTransaction<T>(_ body: () throws -> T) throws -> T {
        do {
            let out = try body()
            try runRaw("COMMIT")
            txDepth = 0
            return out
        } catch {
            // Roll back first: the transaction may already be aborted, and only a
            // rollback makes the connection usable again for the failure settlement.
            try? runRaw("ROLLBACK")
            txDepth = 0
            throw error
        }
    }

    /// Run a query with $1.. text parameters; returns rows as a flat
    /// structure with SQL NULL rendered as the empty string.
    func query(_ sql: String, _ params: [String]) throws -> [[String: String]] {
        try runQuery(sql, params)
    }

    /// Call a function returning jsonb with the service-role claim, WITHOUT
    /// opening a transaction (for lanes that already own one).
    func callFunctionForJSONRaw(_ sql: String, _ params: [String]) throws -> String? {
        try exec("SELECT set_config('request.jwt.claims', '{\"role\":\"service_role\"}', true)")
        let rows = try query(sql, params)
        guard let first = rows.first else { return nil }
        return first.values.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Call a void SECURITY DEFINER function that requires the service-role claim,
    /// inside one transaction that sets the claim and clears it on commit.
    func callAsServiceRole(_ sql: String, _ params: [String]) throws {
        try withTransaction {
            try exec("SELECT set_config('request.jwt.claims', '{\"role\":\"service_role\"}', true)")
            _ = try query(sql, params)
        }
    }

    /// Call a function returning a single jsonb value (as text) with the
    /// service-role claim scoped to the transaction.
    func callFunctionForJSON(_ sql: String, _ params: [String]) throws -> String? {
        try withTransaction {
            try exec("SELECT set_config('request.jwt.claims', '{\"role\":\"service_role\"}', true)")
            let rows = try query(sql, params)
            guard let first = rows.first else { return nil }
            // An empty result set member means the function returned SQL NULL.
            return first.values.first.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    // MARK: - Raw libpq plumbing

    private func runRaw(_ sql: String) throws {
        guard let conn else {
            throw Error(message: "connection closed", sqlstate: nil, kind: .connectionLost)
        }
        if PQstatus(conn) != CONNECTION_OK {
            throw Error(message: "connection lost: \(String(cString: PQerrorMessage(conn)))", sqlstate: nil, kind: .connectionLost)
        }
        let res = PQexec(conn, sql)
        defer { PQclear(res) }
        let status = PQresultStatus(res)
        guard status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK else {
            throw PostgresClient.classify(res, fallback: "exec failed", status: status)
        }
    }

    private func execRaw(_ sql: String) throws {
        guard let conn else { throw Error(message: "connection closed", sqlstate: nil, kind: .connectionLost) }
        let res = PQexec(conn, sql)
        defer { PQclear(res) }
        let status = PQresultStatus(res)
        guard status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK else {
            throw PostgresClient.classify(res, fallback: "exec failed", status: status)
        }
    }

    private func rawQuery(_ sql: String) throws -> [[String: String]] {
        guard let conn else { throw Error(message: "connection closed", sqlstate: nil, kind: .connectionLost) }
        let res = PQexec(conn, sql)
        defer { PQclear(res) }
        let status = PQresultStatus(res)
        guard status == PGRES_TUPLES_OK || status == PGRES_COMMAND_OK else {
            throw PostgresClient.classify(res, fallback: "query failed", status: status)
        }
        return PostgresClient.rows(res)
    }

    private func runQuery(_ sql: String, _ params: [String]) throws -> [[String: String]] {
        guard let conn else {
            throw Error(message: "connection closed", sqlstate: nil, kind: .connectionLost)
        }
        if PQstatus(conn) != CONNECTION_OK {
            throw Error(message: "connection lost: \(String(cString: PQerrorMessage(conn)))", sqlstate: nil, kind: .connectionLost)
        }
        var cParams: [UnsafePointer<CChar>?] = params.map { UnsafePointer(strdup($0)) }
        defer { for p in cParams where p != nil { free(UnsafeMutablePointer(mutating: p!)) } }
        let res = cParams.withUnsafeBufferPointer { buf in
            PQexecParams(conn, sql, Int32(buf.count), nil, buf.baseAddress, nil, nil, 0)
        }
        defer { PQclear(res) }
        // COMMAND_OK (row-less statements like INSERT ... DO NOTHING) is a
        // valid outcome for calls routed through here: return zero rows.
        let status = PQresultStatus(res)
        guard status == PGRES_TUPLES_OK || status == PGRES_COMMAND_OK else {
            throw PostgresClient.classify(res, fallback: "query failed", status: status)
        }
        return PostgresClient.rows(res)
    }

    private static func rows(_ res: OpaquePointer?) -> [[String: String]] {
        guard let res else { return [] }
        let nRows = Int(PQntuples(res)), nCols = Int(PQnfields(res))
        var out: [[String: String]] = []
        out.reserveCapacity(nRows)
        for r in 0..<nRows {
            var row: [String: String] = [:]
            row.reserveCapacity(nCols)
            for c in 0..<nCols {
                let name = String(cString: PQfname(res, Int32(c)))
                row[name] = PQgetisnull(res, Int32(r), Int32(c)) != 0 ? "" : String(cString: PQgetvalue(res, Int32(r), Int32(c)))
            }
            out.append(row)
        }
        return out
    }

    /// Turn a libpq failure into a classified error the lanes can act on.
    static func classify(_ res: OpaquePointer?, fallback: String, status: ExecStatusType) -> Error {
        var detail = res != nil ? String(cString: PQresultErrorMessage(res)) : fallback
        var sqlstate: String?
        if let res, let ptr = PQresultErrorField(res, Int32(0x43)) /* PG_DIAG_SQLSTATE */ {
            sqlstate = String(cString: ptr)
            detail += " [sqlstate=\(sqlstate!)]"
        }
        return Error(message: "\(fallback): status=\(status) \(detail)", sqlstate: sqlstate, kind: kind(forSQLState: sqlstate, status: status))
    }

    static func kind(forSQLState sqlstate: String?, status: ExecStatusType) -> PGErrorKind {
        if status == PGRES_BAD_RESPONSE || (status == PGRES_FATAL_ERROR && sqlstate == nil) {
            return .connectionLost
        }
        return kind(forSQLState: sqlstate)
    }

    /// SQLSTATE-only classification, so the policy is unit-testable without a
    /// libpq result handle.
    static func kind(forSQLState sqlstate: String?) -> PGErrorKind {
        guard let sqlstate, !sqlstate.isEmpty else { return .other }
        if sqlstate.hasPrefix("08") { return .connectionLost }        // connection exception
        if sqlstate == "57P01" || sqlstate == "57P02" || sqlstate == "57P03" { return .connectionLost } // shutdown/crash/cannot connect
        if sqlstate == "40001" || sqlstate == "40P01" { return .serialization }  // serialization/deadlock
        if sqlstate == "25P02" { return .aborted }                    // in_failed_sql_transaction
        if sqlstate == "PT409" { return .stale }                      // engine_publish_legacy_fenced: stale lease
        if sqlstate.hasPrefix("22") { return .deterministic }         // data exception
        if sqlstate.hasPrefix("23") { return .deterministic }         // integrity constraint violation
        if sqlstate == "42501" { return .deterministic }              // insufficient privilege / owner conflict
        if sqlstate == "55000" || sqlstate == "0A000" { return .deterministic }
        return .other
    }

    // MARK: - libpq parameter handling

    /// Parse the caller's connection string with libpq's own parser (it accepts
    /// both `postgresql://` URIs and keyword/value strings), drop the parameters
    /// the worker enforces, and hand back an ordered keyword/value list. This
    /// avoids hand-quoting paths such as a CA file with spaces in it.
    static func resolvedParameters(_ options: PostgresOptions) throws -> [(String, String)] {
        var err: UnsafeMutablePointer<CChar>?
        guard let parsed = PQconninfoParse(options.connectionString, &err) else {
            let msg = err != nil ? String(cString: err!) : "unknown parse error"
            if err != nil { PQfreemem(err) }
            throw Error(message: "invalid FRWHOOP_DB_URL: \(msg)", sqlstate: nil, kind: .other)
        }
        defer { PQconninfoFree(parsed) }

        var pairs: [(String, String)] = []
        var i = 0
        while true {
            let opt = parsed[i]
            guard let keywordPtr = opt.keyword else { break }
            i += 1
            let keyword = String(cString: keywordPtr)
            if let valuePtr = opt.val {
                pairs.append((keyword, String(cString: valuePtr)))
            }
        }

        let overridden: Set<String> = [
            "sslmode", "sslrootcert", "application_name", "connect_timeout",
            "keepalives", "keepalives_idle", "keepalives_interval", "keepalives_count",
        ]
        pairs.removeAll { overridden.contains($0.0) }
        pairs.append(("sslmode", options.sslMode))
        if let ca = options.sslRootCert, !ca.isEmpty {
            pairs.append(("sslrootcert", ca))
        }
        pairs.append(("application_name", options.applicationName))
        pairs.append(("connect_timeout", String(options.connectTimeoutSeconds)))
        pairs.append(("keepalives", "1"))
        pairs.append(("keepalives_idle", "60"))
        pairs.append(("keepalives_interval", "15"))
        pairs.append(("keepalives_count", "4"))
        return pairs
    }

    private static func dial(_ pairs: [(String, String)]) -> OpaquePointer? {
        var keywords: [UnsafePointer<CChar>?] = []
        var values: [UnsafePointer<CChar>?] = []
        var allocated: [UnsafeMutablePointer<CChar>] = []
        for (key, value) in pairs {
            guard let k = strdup(key), let v = strdup(value) else { continue }
            allocated.append(k)
            allocated.append(v)
            keywords.append(UnsafePointer(k))
            values.append(UnsafePointer(v))
        }
        keywords.append(nil)
        values.append(nil)
        let conn = keywords.withUnsafeBufferPointer { keyBuf in
            values.withUnsafeBufferPointer { valueBuf in
                PQconnectdbParams(keyBuf.baseAddress, valueBuf.baseAddress, 0)
            }
        }
        for pointer in allocated { free(pointer) }
        return conn
    }
}
