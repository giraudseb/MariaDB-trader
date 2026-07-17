import CMariaDB
import Foundation

/// Connection parameters for a single MaxScale/MariaDB endpoint.
public struct ConnectionConfig: Sendable, Equatable {
    public var host: String
    public var port: UInt32
    public var user: String
    public var password: String
    public var database: String
    /// Seconds before a connect attempt gives up (fast failover detection).
    public var connectTimeout: UInt32
    /// Seconds before a blocked read gives up.
    public var readTimeout: UInt32
    /// Seconds before a blocked write gives up.
    public var writeTimeout: UInt32

    public init(host: String = "127.0.0.1",
                port: UInt32 = 4006,
                user: String = "app",
                password: String = "app",
                database: String = "trading",
                connectTimeout: UInt32 = 3,
                readTimeout: UInt32 = 5,
                writeTimeout: UInt32 = 5) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.writeTimeout = writeTimeout
    }
}

/// Error raised by a MariaDB operation, carrying the server error number.
public struct MariaError: Error, CustomStringConvertible {
    public let code: UInt32
    public let message: String
    public var description: String { "MariaDB error \(code): \(message)" }

    /// True for errors that mean the connection is gone and we should reconnect.
    public var isConnectionLost: Bool {
        // CR_SERVER_GONE_ERROR 2006, CR_SERVER_LOST 2013, CR_CONN_HOST_ERROR 2003,
        // CR_SERVER_LOST_EXTENDED 2055, ER_CONNECTION_KILLED 1927, plus MaxScale
        // "no valid server" style errors surface as 2003/2006/2013.
        switch code {
        case 2002, 2003, 2006, 2013, 2055, 1927, 1290, 1836, 1053: return true
        default: return code >= 2000 // client-side (CR_*) errors
        }
    }
}

/// A thin, blocking Swift wrapper around one libmariadb `MYSQL*` handle.
/// Not thread-safe: each worker owns exactly one instance on its own thread.
public final class MariaConnection {
    private var handle: UnsafeMutablePointer<MYSQL>?
    public private(set) var isConnected = false

    public init() {}

    deinit { close() }

    /// Opens a connection using the given config. Throws `MariaError` on failure.
    public func connect(_ cfg: ConnectionConfig) throws {
        close()
        guard let h = mysql_init(nil) else {
            throw MariaError(code: 2001, message: "mysql_init failed (out of memory)")
        }
        handle = h

        var ct = cfg.connectTimeout
        var rt = cfg.readTimeout
        var wt = cfg.writeTimeout
        mysql_options(h, MYSQL_OPT_CONNECT_TIMEOUT, &ct)
        mysql_options(h, MYSQL_OPT_READ_TIMEOUT, &rt)
        mysql_options(h, MYSQL_OPT_WRITE_TIMEOUT, &wt)

        let result = cfg.host.withCString { host in
            cfg.user.withCString { user in
                cfg.password.withCString { pass -> UnsafeMutablePointer<MYSQL>? in
                    // Empty database → pass NULL (no default DB) so we can
                    // connect before the database has been created.
                    if cfg.database.isEmpty {
                        return mysql_real_connect(h, host, user, pass, nil, cfg.port, nil, 0)
                    }
                    return cfg.database.withCString { db in
                        mysql_real_connect(h, host, user, pass, db, cfg.port, nil, 0)
                    }
                }
            }
        }
        if result == nil {
            let err = currentError(fallbackCode: 2003)
            close()
            throw err
        }
        isConnected = true
    }

    /// Closes and frees the handle.
    public func close() {
        if let h = handle {
            mysql_close(h)
        }
        handle = nil
        isConnected = false
    }

    /// Lightweight liveness check.
    public func ping() -> Bool {
        guard let h = handle else { return false }
        return mysql_ping(h) == 0
    }

    /// Selects the active database for this connection (equivalent to `USE`).
    /// Uses the client API so no identifier escaping is required.
    public func selectDatabase(_ name: String) throws {
        guard let h = handle else { throw MariaError(code: 2006, message: "not connected") }
        let rc = name.withCString { mysql_select_db(h, $0) }
        if rc != 0 { throw currentError(fallbackCode: 1049) }
    }

    /// Executes a statement that returns no rows (DML/DDL). Throws on error.
    @discardableResult
    public func execute(_ sql: String) throws -> UInt64 {
        guard let h = handle else { throw MariaError(code: 2006, message: "not connected") }
        let rc = sql.withCString { mysql_real_query(h, $0, UInt(strlen($0))) }
        if rc != 0 { throw currentError(fallbackCode: 2013) }
        // Drain any result set to keep the connection clean.
        if let res = mysql_store_result(h) { mysql_free_result(res) }
        return mysql_affected_rows(h)
    }

    /// Executes a query and returns all rows as arrays of optional strings.
    public func query(_ sql: String) throws -> [[String?]] {
        guard let h = handle else { throw MariaError(code: 2006, message: "not connected") }
        let rc = sql.withCString { mysql_real_query(h, $0, UInt(strlen($0))) }
        if rc != 0 { throw currentError(fallbackCode: 2013) }
        guard let res = mysql_store_result(h) else {
            // No result set: either an error or a statement with no output.
            if mysql_errno(h) != 0 { throw currentError(fallbackCode: 2013) }
            return []
        }
        defer { mysql_free_result(res) }
        let fieldCount = Int(mysql_num_fields(res))
        var rows: [[String?]] = []
        while let rowPtr = mysql_fetch_row(res) {
            let lengths = mysql_fetch_lengths(res)
            var row: [String?] = []
            row.reserveCapacity(fieldCount)
            for i in 0..<fieldCount {
                if let cell = rowPtr[i] {
                    let len = lengths?[i] ?? UInt(strlen(cell))
                    row.append(String(decoding: UnsafeBufferPointer(
                        start: UnsafeRawPointer(cell).assumingMemoryBound(to: UInt8.self),
                        count: Int(len)), as: UTF8.self))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - Transactions

    public func begin() throws { try execute("START TRANSACTION") }
    public func commit() throws { try execute("COMMIT") }
    public func rollback() { _ = try? execute("ROLLBACK") }

    /// Escapes a string for safe inline use in SQL.
    public func escape(_ value: String) -> String {
        guard let h = handle else { return value }
        let src = Array(value.utf8)
        var dst = [CChar](repeating: 0, count: src.count * 2 + 1)
        let written = src.withUnsafeBufferPointer { sp -> UInt in
            sp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: sp.count) { cp in
                mysql_real_escape_string(h, &dst, cp, UInt(sp.count))
            }
        }
        return String(cString: Array(dst[0..<Int(written)]) + [0])
    }

    private func currentError(fallbackCode: UInt32) -> MariaError {
        guard let h = handle else {
            return MariaError(code: fallbackCode, message: "connection unavailable")
        }
        let code = mysql_errno(h)
        let msg = String(cString: mysql_error(h))
        return MariaError(code: code == 0 ? fallbackCode : code,
                          message: msg.isEmpty ? "unknown error" : msg)
    }
}
