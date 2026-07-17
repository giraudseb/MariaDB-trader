import Foundation
import TradingCore

// Headless driver: runs the real WorkloadEngine against a live MariaDB/MaxScale
// endpoint for a few seconds and prints the resulting metrics. Env overrides:
//   DB_HOST DB_PORT DB_USER DB_PASS DB_NAME RUN_SECONDS WORKERS
let env = ProcessInfo.processInfo.environment
func s(_ k: String, _ d: String) -> String { env[k] ?? d }
func i(_ k: String, _ d: Int) -> Int { Int(env[k] ?? "") ?? d }

let cfg = ConnectionConfig(
    host: s("DB_HOST", "127.0.0.1"),
    port: UInt32(i("DB_PORT", 3306)),
    user: s("DB_USER", "app"),
    password: s("DB_PASS", "app"),
    database: s("DB_NAME", "trading"))

let runSeconds = i("RUN_SECONDS", 5)
let workers = i("WORKERS", 6)

print("SmokeTest → \(cfg.host):\(cfg.port) db=\(cfg.database) workers=\(workers) for \(runSeconds)s")

let engine = WorkloadEngine()
engine.onStatus = { print("  [status] \($0)") }
engine.start(config: cfg, params: WorkloadParams(workers: workers, readRatio: 0.7,
                                                 ratePerWorker: 0, accounts: 200))

Thread.sleep(forTimeInterval: TimeInterval(runSeconds))
let snap = engine.store.snapshot(now: Date())
engine.stop()
Thread.sleep(forTimeInterval: 0.5)

print("\n===== RESULTS =====")
print("committed : \(snap.totalCommitted)")
print("failed    : \(snap.totalFailed)")
print(String(format: "error rate: %.3f%%", snap.errorRate))
print(String(format: "TPS (recent): %.0f  (reads %.0f / writes %.0f)",
             snap.currentTPS, snap.currentReadTPS, snap.currentWriteTPS))
print(String(format: "p95 latency: %.2f ms", snap.p95Latency))
print("servers observed:")
for srv in snap.servers { print("  - \(srv.id): reads=\(srv.reads) writes=\(srv.writes)") }
print("connections: \(snap.connections.count), outages: \(snap.outages.count)")

if snap.totalCommitted == 0 {
    print("FAIL: no committed transactions")
    exit(1)
}
print("PASS")
exit(0)
