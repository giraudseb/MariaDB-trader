import Foundation

public enum OpKind: String, Sendable {
    case read
    case write
}

public enum ConnStatus: String, Sendable {
    case connecting
    case idle
    case busy
    case reconnecting
    case error
    case stopped
}

/// Per-second aggregate used to draw the time-series charts.
public struct SecondBucket: Sendable, Identifiable {
    public var second: Int          // epoch seconds
    public var committed: Int = 0
    public var failed: Int = 0
    public var reads: Int = 0
    public var writes: Int = 0
    public var p50: Double = 0      // ms
    public var p95: Double = 0      // ms
    public var p99: Double = 0      // ms
    public var avg: Double = 0      // ms
    public var id: Int { second }
}

/// Live state of one worker connection.
public struct ConnSnapshot: Sendable, Identifiable {
    public var id: Int
    public var status: ConnStatus = .connecting
    public var ops: Int = 0
    public var errors: Int = 0
    public var reconnects: Int = 0
    public var lastWriteServer: String = "—"
    public var lastReadServer: String = "—"
    public var lastError: String = ""
    public var lastLatencyMs: Double = 0
}

/// A detected outage window (connection lost -> recovered).
public struct OutageEvent: Sendable, Identifiable {
    public var id: Int
    public var connId: Int
    public var start: Date
    public var end: Date?
    public var durationMs: Double?
    public var reason: String
}

/// How each backend server has served traffic (read/write split view).
public struct ServerLoad: Sendable, Identifiable {
    public var id: String       // server label (@@hostname / server_id)
    public var reads: Int = 0
    public var writes: Int = 0
}

/// Immutable view handed to the UI on every refresh.
public struct MetricsSnapshot: Sendable {
    public var totalCommitted: Int = 0
    public var totalFailed: Int = 0
    public var currentTPS: Double = 0
    public var currentReadTPS: Double = 0
    public var currentWriteTPS: Double = 0
    public var p95Latency: Double = 0
    public var errorRate: Double = 0
    public var history: [SecondBucket] = []
    public var connections: [ConnSnapshot] = []
    public var servers: [ServerLoad] = []
    public var outages: [OutageEvent] = []
    public var activeOutages: Int = 0
    public var totalDowntimeMs: Double = 0
    public var running: Bool = false
    public var startedAt: Date?

    public init() {}
}

/// Thread-safe metrics aggregator. Written by many worker threads,
/// read by the UI on the main thread. All access is lock-guarded.
public final class MetricsStore: @unchecked Sendable {
    private let lock = NSLock()

    private var totalCommitted = 0
    private var totalFailed = 0
    private var history: [SecondBucket] = []          // rolling, capped
    private var currentSecond = 0
    private var currentLatencies: [Double] = []
    private var currentCommitted = 0
    private var currentFailed = 0
    private var currentReads = 0
    private var currentWrites = 0

    private var connections: [Int: ConnSnapshot] = [:]
    private var servers: [String: ServerLoad] = [:]
    private var outages: [OutageEvent] = []
    private var openOutageByConn: [Int: Int] = [:]    // connId -> index in outages
    private var outageSeq = 0
    private var totalDowntimeMs: Double = 0
    private var startedAt: Date?

    private let historyWindow = 180                    // seconds retained

    public init() {}

    public func reset(connectionCount: Int, at now: Date) {
        lock.lock(); defer { lock.unlock() }
        totalCommitted = 0; totalFailed = 0
        history.removeAll()
        currentSecond = Int(now.timeIntervalSince1970)
        currentLatencies.removeAll()
        currentCommitted = 0; currentFailed = 0; currentReads = 0; currentWrites = 0
        connections.removeAll()
        servers.removeAll()
        outages.removeAll()
        openOutageByConn.removeAll()
        totalDowntimeMs = 0
        outageSeq = 0
        startedAt = now
        for i in 0..<connectionCount {
            connections[i] = ConnSnapshot(id: i)
        }
    }

    // MARK: - Writes (worker threads)

    public func recordOp(kind: OpKind, latencyMs: Double, server: String,
                         connId: Int, at now: Date) {
        lock.lock(); defer { lock.unlock() }
        rollTo(second: Int(now.timeIntervalSince1970))
        totalCommitted += 1
        currentCommitted += 1
        currentLatencies.append(latencyMs)
        switch kind {
        case .read: currentReads += 1
        case .write: currentWrites += 1
        }
        var s = servers[server] ?? ServerLoad(id: server)
        if kind == .read { s.reads += 1 } else { s.writes += 1 }
        servers[server] = s

        if var c = connections[connId] {
            c.ops += 1
            c.status = .busy
            c.lastLatencyMs = latencyMs
            if kind == .read { c.lastReadServer = server } else { c.lastWriteServer = server }
            connections[connId] = c
        }
        // Any success closes an open outage for this connection.
        closeOutage(connId: connId, at: now)
    }

    public func recordFailure(connId: Int, error: MariaError, at now: Date) {
        lock.lock(); defer { lock.unlock() }
        rollTo(second: Int(now.timeIntervalSince1970))
        totalFailed += 1
        currentFailed += 1
        if var c = connections[connId] {
            c.errors += 1
            c.status = .error
            c.lastError = error.description
            connections[connId] = c
        }
        if error.isConnectionLost {
            openOutage(connId: connId, reason: error.description, at: now)
        }
    }

    public func setStatus(connId: Int, _ status: ConnStatus, at now: Date) {
        lock.lock(); defer { lock.unlock() }
        if var c = connections[connId] {
            c.status = status
            connections[connId] = c
        }
        if status == .reconnecting {
            openOutage(connId: connId, reason: "reconnecting", at: now)
        }
    }

    public func recordReconnect(connId: Int, at now: Date) {
        lock.lock(); defer { lock.unlock() }
        if var c = connections[connId] {
            c.reconnects += 1
            c.status = .idle
            connections[connId] = c
        }
        closeOutage(connId: connId, at: now)
    }

    // MARK: - Read (main thread)

    public func snapshot(now: Date) -> MetricsSnapshot {
        lock.lock(); defer { lock.unlock() }
        rollTo(second: Int(now.timeIntervalSince1970))

        var snap = MetricsSnapshot()
        snap.totalCommitted = totalCommitted
        snap.totalFailed = totalFailed
        snap.history = history
        snap.connections = connections.values.sorted { $0.id < $1.id }
        snap.servers = servers.values.sorted { $0.id < $1.id }
        snap.outages = outages.sorted { $0.start > $1.start }
        snap.activeOutages = openOutageByConn.count
        snap.totalDowntimeMs = totalDowntimeMs + currentOpenDowntime(now: now)
        snap.startedAt = startedAt

        // Rates from the most recent *completed* seconds (exclude current).
        let completed = history.filter { $0.second < currentSecond }
        let recent = completed.suffix(5)
        if !recent.isEmpty {
            snap.currentTPS = Double(recent.reduce(0) { $0 + $1.committed }) / Double(recent.count)
            snap.currentReadTPS = Double(recent.reduce(0) { $0 + $1.reads }) / Double(recent.count)
            snap.currentWriteTPS = Double(recent.reduce(0) { $0 + $1.writes }) / Double(recent.count)
            snap.p95Latency = recent.map { $0.p95 }.max() ?? 0
        }
        let denom = totalCommitted + totalFailed
        snap.errorRate = denom > 0 ? Double(totalFailed) / Double(denom) * 100 : 0
        return snap
    }

    // MARK: - Internals (must hold lock)

    private func rollTo(second: Int) {
        if currentSecond == 0 { currentSecond = second }
        while second > currentSecond {
            history.append(finishBucket(currentSecond))
            if history.count > historyWindow { history.removeFirst(history.count - historyWindow) }
            currentSecond += 1
            currentLatencies.removeAll(keepingCapacity: true)
            currentCommitted = 0; currentFailed = 0; currentReads = 0; currentWrites = 0
        }
    }

    private func finishBucket(_ second: Int) -> SecondBucket {
        var b = SecondBucket(second: second)
        b.committed = currentCommitted
        b.failed = currentFailed
        b.reads = currentReads
        b.writes = currentWrites
        if !currentLatencies.isEmpty {
            let sorted = currentLatencies.sorted()
            b.p50 = percentile(sorted, 0.50)
            b.p95 = percentile(sorted, 0.95)
            b.p99 = percentile(sorted, 0.99)
            b.avg = currentLatencies.reduce(0, +) / Double(currentLatencies.count)
        }
        return b
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }

    private func openOutage(connId: Int, reason: String, at now: Date) {
        guard openOutageByConn[connId] == nil else { return }
        let event = OutageEvent(id: outageSeq, connId: connId, start: now,
                                end: nil, durationMs: nil, reason: reason)
        outages.append(event)
        openOutageByConn[connId] = outages.count - 1
        outageSeq += 1
    }

    private func closeOutage(connId: Int, at now: Date) {
        guard let idx = openOutageByConn[connId] else { return }
        let d = now.timeIntervalSince(outages[idx].start) * 1000
        outages[idx].end = now
        outages[idx].durationMs = d
        totalDowntimeMs += d
        openOutageByConn[connId] = nil
    }

    private func currentOpenDowntime(now: Date) -> Double {
        openOutageByConn.values.reduce(0.0) { acc, idx in
            acc + now.timeIntervalSince(outages[idx].start) * 1000
        }
    }
}
