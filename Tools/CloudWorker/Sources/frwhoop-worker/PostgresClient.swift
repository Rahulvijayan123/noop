
import Foundation
import CLibPQ

/// A single Postgres connection over libpq with JSON-value helpers.
///
/// The worker connects with its own Postgres credentials (never the service-role
/// HTTP key) and calls the SECURITY DEFINER work-queue functions directly. A
/// transaction-scoped `request.jwt.claims` GUC is set where a queue function
/// checks `auth.role()`; the claim never leaves the current transaction.
final class PostgresClient {
    private var conn: OpaquePointer?

    struct Error: Swift.Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    init(connectionString: String) throws {
        conn = PQconnectdb(connectionString)
        guard let conn, PQstatus(conn) == CONNECTION_OK else {
            let msg = conn != nil ? String(cString: PQerrorMessage(conn)) : "libpq allocation failure"
            throw Error(message: "postgres connect failed: \(msg)")
        }
        // Keep TCP keepalive + a sane receive timeout so a wedged connection
        // surfaces as an error instead of a forever-stuck lane loop.
        PQexec(conn, "SET tcp_keepalives_idle = 60")
        PQexec(conn, "SET tcp_keepalives_interval = 15")
        PQexec(conn, "SET tcp_keepalives_count = 4")
        PQexec(conn, "SET statement_timeout = '120s'")
    }

    deinit {
        if let conn { PQfinish(conn) }
    }

    var isConnected: Bool { conn != nil && PQstatus(conn) == CONNECTION_OK }

    /// Run one statement; throw on non-OK command status.
    func exec(_ sql: String) throws {
        guard let conn else { throw Error(message: "connection closed") }
        let res = PQexec(conn, sql)
        defer { PQclear(res) }
        let status = PQresultStatus(res)
        guard status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK else {
            throw Error(message: "exec failed: \(String(cString: PQresultErrorMessage(res)))")
        }
    }

    /// Begin a transaction, run `body`, and commit only if body returns normally.
    /// Nested begin is refused: lanes never overlap transactions on one connection.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN")
        do {
            let out = try body()
            try exec("COMMIT")
            return out
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// A REPEATABLE READ transaction: the fenced input snapshot the scoring
    /// lane requires (claim, seal, publish and finish must share one txid).
    func withRepeatableRead<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN ISOLATION LEVEL REPEATABLE READ")
        do {
            let out = try body()
            try exec("COMMIT")
            return out
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Run a query with $1.. text parameters; returns rows as a flat
    /// structure with SQL NULL rendered as the empty string.
    func query(_ sql: String, _ params: [String]) throws -> [[String: String]] {
        guard let conn else { throw Error(message: "connection closed") }
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
            var detail = String(cString: PQresultErrorMessage(res))
            if let sqlstatePtr = PQresultErrorField(res, Int32(0x43)) /* PG_DIAG_SQLSTATE */ {
                detail += " [sqlstate=\(String(cString: sqlstatePtr))]"
            }
            throw Error(message: "query failed: status=\(status) \(detail)")
        }
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
}
