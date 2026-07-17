import SwiftUI
import Charts
import TradingCore

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var state: AppState
    private let cols = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    var body: some View {
        let s = state.snapshot
        ScrollView {
            VStack(spacing: 14) {
                LazyVGrid(columns: cols, spacing: 12) {
                    StatTile(title: "Throughput", value: String(format: "%.0f", s.currentTPS),
                             subtitle: "committed tx/s", color: Theme.accent, systemImage: "bolt.fill")
                    StatTile(title: "Reads / Writes", value: "\(Int(s.currentReadTPS)) / \(Int(s.currentWriteTPS))",
                             subtitle: "tx/s split", color: Theme.read, systemImage: "arrow.left.arrow.right")
                    StatTile(title: "p95 latency", value: s.p95Latency.ms(),
                             subtitle: "recent window", color: Theme.warn, systemImage: "timer")
                    StatTile(title: "Committed", value: s.totalCommitted.grouped,
                             subtitle: "total tx", color: Theme.good, systemImage: "checkmark.seal.fill")
                    StatTile(title: "Failed", value: s.totalFailed.grouped,
                             subtitle: String(format: "%.2f%% error rate", s.errorRate),
                             color: s.totalFailed > 0 ? Theme.bad : Theme.muted,
                             systemImage: "exclamationmark.triangle.fill")
                    StatTile(title: "Downtime", value: String(format: "%.1f s", s.totalDowntimeMs / 1000),
                             subtitle: s.activeOutages > 0 ? "\(s.activeOutages) active" : "recovered",
                             color: s.activeOutages > 0 ? Theme.bad : Theme.good,
                             systemImage: "arrow.triangle.2.circlepath")
                }

                Card(title: "Committed transactions/s", systemImage: "chart.bar.fill") {
                    TPSChart(buckets: s.window())
                }

                if !state.isRunning && s.totalCommitted == 0 {
                    EmptyHint()
                }
            }
            .padding(4)
        }
    }
}

struct EmptyHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "play.circle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Press **Start workload** to begin generating trading traffic.")
                .foregroundStyle(.secondary)
            Text("Then stop your primary node (or run a MaxScale switchover) to watch failover continuity.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(30)
    }
}

// MARK: - Throughput & Latency

struct ThroughputView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        let s = state.snapshot
        ScrollView {
            VStack(spacing: 14) {
                Card(title: "Transactions per second (reads vs writes)", systemImage: "chart.xyaxis.line") {
                    TPSChart(buckets: s.window(), stacked: true)
                }
                Card(title: "Latency percentiles (ms)", systemImage: "timer") {
                    LatencyChart(buckets: s.window())
                }
            }.padding(4)
        }
    }
}

struct TPSChart: View {
    var buckets: [SecondBucket]
    var stacked: Bool = false
    private var base: Int { buckets.first?.second ?? 0 }

    var body: some View {
        Chart {
            ForEach(buckets) { b in
                if stacked {
                    AreaMark(x: .value("t", b.second - base),
                             y: .value("tx/s", b.reads),
                             stacking: .standard)
                        .foregroundStyle(by: .value("kind", "reads"))
                    AreaMark(x: .value("t", b.second - base),
                             y: .value("tx/s", b.writes),
                             stacking: .standard)
                        .foregroundStyle(by: .value("kind", "writes"))
                } else {
                    BarMark(x: .value("t", b.second - base),
                            y: .value("tx/s", b.committed))
                        .foregroundStyle(Theme.accent.gradient)
                }
                if b.failed > 0 {
                    PointMark(x: .value("t", b.second - base),
                              y: .value("failed", b.failed))
                        .foregroundStyle(Theme.bad)
                        .symbolSize(30)
                }
            }
        }
        .chartForegroundStyleScale(["reads": Theme.read, "writes": Theme.accent])
        .chartXAxisLabel("seconds")
        .chartLegend(.visible)
        .frame(height: 240)
    }
}

struct LatencyChart: View {
    var buckets: [SecondBucket]
    private var base: Int { buckets.first?.second ?? 0 }

    var body: some View {
        Chart {
            ForEach(buckets) { b in
                LineMark(x: .value("t", b.second - base), y: .value("ms", b.p50),
                         series: .value("s", "p50")).foregroundStyle(Theme.good)
                LineMark(x: .value("t", b.second - base), y: .value("ms", b.p95),
                         series: .value("s", "p95")).foregroundStyle(Theme.warn)
                LineMark(x: .value("t", b.second - base), y: .value("ms", b.p99),
                         series: .value("s", "p99")).foregroundStyle(Theme.bad)
            }
        }
        .chartForegroundStyleScale(["p50": Theme.good, "p95": Theme.warn, "p99": Theme.bad])
        .chartXAxisLabel("seconds")
        .chartLegend(.visible)
        .frame(height: 240)
    }
}
