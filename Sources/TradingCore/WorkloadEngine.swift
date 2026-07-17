import Foundation

/// Tunable workload parameters that can change while running.
public struct WorkloadParams: Sendable, Equatable {
    public var workers: Int
    public var readRatio: Double        // 0.0 ... 1.0 fraction of ops that are reads
    public var ratePerWorker: Int       // target ops/sec per worker; 0 = unthrottled
    public var accounts: Int

    public init(workers: Int = 8, readRatio: Double = 0.7,
                ratePerWorker: Int = 0, accounts: Int = 200) {
        self.workers = workers
        self.readRatio = readRatio
        self.ratePerWorker = ratePerWorker
        self.accounts = accounts
    }
}

/// Orchestrates N worker threads, each owning one MariaDB connection through
/// MaxScale, generating a mixed read/write trading workload and reporting to
/// a shared `MetricsStore`.
public final class WorkloadEngine: @unchecked Sendable {
    public let store = MetricsStore()

    private let ctrl = NSLock()
    private var _running = false
    private var _paused = false
    private var _config = ConnectionConfig()
    private var _params = WorkloadParams()
    private var threads: [Thread] = []

    /// Called (on an arbitrary thread) with human-readable status lines.
    public var onStatus: (@Sendable (String) -> Void)?

    public init() {}

    // MARK: - Thread-safe accessors

    public var isRunning: Bool { ctrl.lock(); defer { ctrl.unlock() }; return _running }
    public var isPaused: Bool { ctrl.lock(); defer { ctrl.unlock() }; return _paused }

    public func setPaused(_ v: Bool) { ctrl.lock(); _paused = v; ctrl.unlock() }
    public func setReadRatio(_ v: Double) {
        ctrl.lock(); _params.readRatio = min(max(v, 0), 1); ctrl.unlock()
    }
    public func setRate(_ v: Int) { ctrl.lock(); _params.ratePerWorker = max(0, v); ctrl.unlock() }

    private func snapshotControl() -> (running: Bool, paused: Bool, params: WorkloadParams, cfg: ConnectionConfig) {
        ctrl.lock(); defer { ctrl.unlock() }
        return (_running, _paused, _params, _config)
    }

    // MARK: - Lifecycle

    public func start(config: ConnectionConfig, params: WorkloadParams) {
        ctrl.lock()
        if _running { ctrl.unlock(); return }
        _running = true
        _paused = false
        _config = config
        _params = params
        ctrl.unlock()

        store.reset(connectionCount: params.workers, at: Date())
        status("Starting \(params.workers) workers → \(config.host):\(config.port)")

        // Coordinator thread: bootstrap schema, then launch workers.
        let coordinator = Thread { [weak self] in
            guard let self else { return }
            self.bootstrapThenRun(config: config, params: params)
        }
        coordinator.name = "mariatrader.coordinator"
        coordinator.stackSize = 1 << 20
        coordinator.start()
    }

    public func stop() {
        ctrl.lock()
        _running = false
        _paused = false
        let ts = threads
        threads = []
        ctrl.unlock()
        status("Stopping…")
        // Workers observe _running == false and exit their loops.
        for t in ts where t.isExecuting { /* they self-terminate */ _ = t }
    }

    // MARK: - Coordinator

    private func bootstrapThenRun(config: ConnectionConfig, params: WorkloadParams) {
        let setup = MariaConnection()
        do {
            // Connect without selecting a database so we can create it if the
            // target database does not exist yet, then switch into it.
            var adminCfg = config
            adminCfg.database = ""
            try setup.connect(adminCfg)
            status("Connected. Ensuring database '\(config.database)' exists…")
            try Schema.ensureDatabase(setup, name: config.database)
            try setup.selectDatabase(config.database)
            status("Applying schema + seeding \(params.accounts) accounts…")
            try Schema.bootstrap(setup, accounts: params.accounts)
            setup.close()
            status("Schema ready. Launching workers.")
        } catch {
            setup.close()
            status("Bootstrap failed: \(error). Is MaxScale reachable and the account allowed to CREATE DATABASE?")
            ctrl.lock(); _running = false; ctrl.unlock()
            return
        }

        var launched: [Thread] = []
        for i in 0..<params.workers {
            let t = Thread { [weak self] in self?.workerLoop(id: i, config: config) }
            t.name = "mariatrader.worker.\(i)"
            t.stackSize = 1 << 20
            launched.append(t)
        }
        ctrl.lock(); threads = launched; ctrl.unlock()
        launched.forEach { $0.start() }
    }

    // MARK: - Worker

    private func workerLoop(id: Int, config: ConnectionConfig) {
        var rng = SystemRandomNumberGenerator()
        let conn = MariaConnection()
        let syms = Schema.instruments

        // Initial connect with retry.
        if !ensureConnected(conn, id: id) { return }

        while snapshotControl().running {
            let (_, paused, params, _) = snapshotControl()
            if paused {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            let isRead = Double.random(in: 0..<1, using: &rng) < params.readRatio
            let opStart = Date()
            do {
                let server: String
                if isRead {
                    server = try doRead(conn, syms: syms, rng: &rng)
                    store.recordOp(kind: .read, latencyMs: elapsedMs(opStart),
                                   server: server, connId: id, at: Date())
                } else {
                    server = try doWrite(conn, syms: syms, accounts: params.accounts, rng: &rng)
                    store.recordOp(kind: .write, latencyMs: elapsedMs(opStart),
                                   server: server, connId: id, at: Date())
                }
            } catch let e as MariaError {
                conn.rollback()
                store.recordFailure(connId: id, error: e, at: Date())
                if e.isConnectionLost {
                    status("Worker \(id): connection lost (\(e.code)); reconnecting…")
                    if !reconnect(conn, id: id) { break }
                } else {
                    // Transient (deadlock/lock wait/etc.): brief pause, keep going.
                    Thread.sleep(forTimeInterval: 0.02)
                }
            } catch {
                conn.rollback()
                store.recordFailure(connId: id,
                                    error: MariaError(code: 9999, message: "\(error)"),
                                    at: Date())
            }

            // Throttle to target rate if requested.
            if params.ratePerWorker > 0 {
                let target = 1.0 / Double(params.ratePerWorker)
                let spent = Date().timeIntervalSince(opStart)
                if spent < target { Thread.sleep(forTimeInterval: target - spent) }
            }
        }
        conn.close()
        store.setStatus(connId: id, .stopped, at: Date())
    }

    // MARK: - Connection helpers

    private func ensureConnected(_ conn: MariaConnection, id: Int) -> Bool {
        store.setStatus(connId: id, .connecting, at: Date())
        var backoff = 0.25
        while snapshotControl().running {
            do {
                try conn.connect(snapshotControl().cfg)
                store.recordReconnect(connId: id, at: Date())
                return true
            } catch {
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 2.0)
            }
        }
        return false
    }

    private func reconnect(_ conn: MariaConnection, id: Int) -> Bool {
        store.setStatus(connId: id, .reconnecting, at: Date())
        conn.close()
        var backoff = 0.1
        while snapshotControl().running {
            do {
                try conn.connect(snapshotControl().cfg)
                store.recordReconnect(connId: id, at: Date())
                status("Worker \(id): reconnected.")
                return true
            } catch {
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 2.0)
            }
        }
        return false
    }

    // MARK: - Trading operations

    /// Read path: routed by MaxScale to a replica. Returns the serving node label.
    private func doRead(_ conn: MariaConnection, syms: [String],
                        rng: inout SystemRandomNumberGenerator) throws -> String {
        let sym = syms.randomElement(using: &rng) ?? "MDB"
        let server = try serverLabel(conn)
        _ = try conn.query("SELECT symbol, last_price FROM instruments WHERE symbol = '\(sym)'")
        _ = try conn.query("""
            SELECT id, qty, price FROM trades
            WHERE symbol = '\(sym)' ORDER BY executed_at DESC LIMIT 10
            """)
        return server
    }

    /// Write path: a trade transaction, routed by MaxScale to the primary.
    private func doWrite(_ conn: MariaConnection, syms: [String], accounts: Int,
                         rng: inout SystemRandomNumberGenerator) throws -> String {
        let sym = syms.randomElement(using: &rng) ?? "MDB"
        let buyer = Int.random(in: 0..<accounts, using: &rng)
        var seller = Int.random(in: 0..<accounts, using: &rng)
        if seller == buyer { seller = (seller + 1) % accounts }
        let qty = Int.random(in: 1...1000, using: &rng)
        let price = Double.random(in: 50...500, using: &rng)
        let notional = Double(qty) * price
        let p = String(format: "%.4f", price)
        let n = String(format: "%.2f", notional)

        try conn.begin()
        do {
            try conn.execute("INSERT INTO orders (account_id,symbol,side,qty,price) VALUES (\(buyer),'\(sym)','BUY',\(qty),\(p))")
            try conn.execute("INSERT INTO orders (account_id,symbol,side,qty,price,status) VALUES (\(seller),'\(sym)','SELL',\(qty),\(p),'FILLED')")
            try conn.execute("INSERT INTO trades (symbol,qty,price,buyer_id,seller_id) VALUES ('\(sym)',\(qty),\(p),\(buyer),\(seller))")
            try conn.execute("UPDATE accounts SET balance = balance - \(n) WHERE id = \(buyer)")
            try conn.execute("UPDATE accounts SET balance = balance + \(n) WHERE id = \(seller)")
            try conn.execute("UPDATE instruments SET last_price = \(p), updated_at = CURRENT_TIMESTAMP(3) WHERE symbol = '\(sym)'")
            let server = try serverLabel(conn)   // routed to primary inside the txn
            try conn.commit()
            return server
        } catch {
            conn.rollback()
            throw error
        }
    }

    /// Reads the identity of the backend that served the connection's last route.
    private func serverLabel(_ conn: MariaConnection) throws -> String {
        let rows = try conn.query("SELECT @@server_id, @@hostname")
        guard let row = rows.first else { return "unknown" }
        let sid = row.count > 0 ? (row[0] ?? "?") : "?"
        let host = row.count > 1 ? (row[1] ?? "") : ""
        return host.isEmpty ? "srv-\(sid)" : "\(host) (id \(sid))"
    }

    private func elapsedMs(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }

    private func status(_ msg: String) { onStatus?(msg) }
}
