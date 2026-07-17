import Foundation
import SwiftUI
import TradingCore

/// Observable bridge between the SwiftUI views and the workload engine.
@MainActor
final class AppState: ObservableObject {
    // Connection settings (bound to the config form).
    @Published var host = "127.0.0.1"
    @Published var port = "4000"
    @Published var user = "seb"
    @Published var password = "MyPassw0rd#"
    @Published var database = "trading"
    
    // Workload settings.
    @Published var workers = 8.0
    @Published var readRatio = 0.7            // fraction of ops that are reads
    @Published var ratePerWorker = 0.0        // ops/sec/worker, 0 = unthrottled
    @Published var accounts = 200.0

    // Live state.
    @Published var snapshot = MetricsSnapshot()
    @Published var isRunning = false
    @Published var isPaused = false
    @Published private(set) var log: [String] = []

    private let engine = WorkloadEngine()
    private var timer: Timer?

    init() {
        engine.onStatus = { [weak self] msg in
            Task { @MainActor in self?.append(msg) }
        }
    }

    var config: ConnectionConfig {
        ConnectionConfig(host: host,
                         port: UInt32(port) ?? 4006,
                         user: user,
                         password: password,
                         database: database)
    }

    var params: WorkloadParams {
        WorkloadParams(workers: Int(workers),
                       readRatio: readRatio,
                       ratePerWorker: Int(ratePerWorker),
                       accounts: Int(accounts))
    }

    func start() {
        guard !isRunning else { return }
        append("▶ Starting workload…")
        engine.start(config: config, params: params)
        isRunning = true
        isPaused = false
        startTimer()
    }

    func stop() {
        engine.stop()
        isRunning = false
        isPaused = false
        // Keep the timer briefly so the UI reflects the final state, then refresh once.
        refresh()
    }

    func togglePause() {
        isPaused.toggle()
        engine.setPaused(isPaused)
        append(isPaused ? "⏸ Paused" : "▶ Resumed")
    }

    func applyLiveTuning() {
        engine.setReadRatio(readRatio)
        engine.setRate(Int(ratePerWorker))
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        snapshot = engine.store.snapshot(now: Date())
        // Detect engine self-stop (e.g. bootstrap failure).
        if isRunning && !engine.isRunning {
            isRunning = false
            timer?.invalidate()
        }
    }

    private func append(_ msg: String) {
        let stamp = Self.formatter.string(from: Date())
        log.append("[\(stamp)] \(msg)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
