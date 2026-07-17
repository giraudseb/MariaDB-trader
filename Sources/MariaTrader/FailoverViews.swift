import SwiftUI
import Charts
import TradingCore

// MARK: - Failover continuity

struct FailoverView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let s = state.snapshot
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    StatTile(title: "Active outages", value: "\(s.activeOutages)",
                             subtitle: s.activeOutages > 0 ? "recovering…" : "all healthy",
                             color: s.activeOutages > 0 ? Theme.bad : Theme.good,
                             systemImage: "bolt.horizontal.circle")
                    StatTile(title: "Cumulative downtime", value: String(format: "%.2f s", s.totalDowntimeMs / 1000),
                             subtitle: "summed across connections", color: Theme.warn, systemImage: "clock.badge.exclamationmark")
                    StatTile(title: "Failover events", value: "\(s.outages.count)",
                             subtitle: "connection losses", color: Theme.accent, systemImage: "arrow.triangle.2.circlepath")
                    StatTile(title: "Availability", value: availabilityString(s),
                             subtitle: "committed vs failed", color: Theme.good, systemImage: "checkmark.shield.fill")
                }

                Card(title: "Committed vs failed over time", systemImage: "chart.xyaxis.line") {
                    ContinuityChart(buckets: s.window())
                    Text("A brief spike in failures with an immediate return to committed traffic is the failover story: MaxScale re-routes to a healthy node and the clients auto-reconnect.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Card(title: "Outage timeline", systemImage: "list.bullet.rectangle") {
                    if s.outages.isEmpty {
                        Text("No connection losses detected yet. Trigger a failover (stop the primary, or run a MaxScale switchover) to populate this list.")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                    } else {
                        OutageTable(outages: s.outages)
                    }
                }
            }.padding(4)
        }
    }

    private func availabilityString(_ s: MetricsSnapshot) -> String {
        let total = s.totalCommitted + s.totalFailed
        guard total > 0 else { return "—" }
        return String(format: "%.3f%%", Double(s.totalCommitted) / Double(total) * 100)
    }
}

struct ContinuityChart: View {
    var buckets: [SecondBucket]
    private var base: Int { buckets.first?.second ?? 0 }

    var body: some View {
        Chart {
            ForEach(buckets) { b in
                AreaMark(x: .value("t", b.second - base), y: .value("committed", b.committed))
                    .foregroundStyle(Theme.good.opacity(0.25))
                LineMark(x: .value("t", b.second - base), y: .value("committed", b.committed),
                         series: .value("s", "committed"))
                    .foregroundStyle(Theme.good)
                BarMark(x: .value("t", b.second - base), y: .value("failed", b.failed))
                    .foregroundStyle(Theme.bad)
            }
        }
        .chartXAxisLabel("seconds")
        .frame(height: 240)
    }
}

struct OutageTable: View {
    var outages: [OutageEvent]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conn").frame(width: 50, alignment: .leading)
                Text("Started").frame(width: 90, alignment: .leading)
                Text("Duration").frame(width: 90, alignment: .leading)
                Text("Reason").frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption.bold()).foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(outages.prefix(50)) { o in
                HStack {
                    Text("#\(o.connId)").frame(width: 50, alignment: .leading)
                    Text(Self.fmt.string(from: o.start)).frame(width: 90, alignment: .leading)
                    if let d = o.durationMs {
                        Text(String(format: "%.0f ms", d)).frame(width: 90, alignment: .leading)
                            .foregroundStyle(d > 1000 ? Theme.warn : Theme.good)
                    } else {
                        Text("ongoing").frame(width: 90, alignment: .leading).foregroundStyle(Theme.bad)
                    }
                    Text(o.reason).frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1).foregroundStyle(.secondary)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.vertical, 2)
                Divider().opacity(0.4)
            }
        }
    }
    static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}

// MARK: - Read/Write split

struct SplitView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        let s = state.snapshot
        ScrollView {
            VStack(spacing: 14) {
                Card(title: "Traffic by backend node", systemImage: "server.rack") {
                    if s.servers.isEmpty {
                        Text("No server routing observed yet. Start the workload — read queries are routed by MaxScale to replicas, write transactions to the primary.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ServerSplitChart(servers: s.servers)
                    }
                }
                Card(title: "Per-node breakdown", systemImage: "tablecells") {
                    ServerTable(servers: s.servers)
                }
            }.padding(4)
        }
    }
}

struct ServerSplitChart: View {
    var servers: [ServerLoad]
    var body: some View {
        Chart {
            ForEach(servers) { srv in
                BarMark(x: .value("node", srv.id), y: .value("ops", srv.reads))
                    .foregroundStyle(by: .value("kind", "reads"))
                BarMark(x: .value("node", srv.id), y: .value("ops", srv.writes))
                    .foregroundStyle(by: .value("kind", "writes"))
            }
        }
        .chartForegroundStyleScale(["reads": Theme.read, "writes": Theme.accent])
        .chartLegend(.visible)
        .frame(height: 260)
    }
}

struct ServerTable: View {
    var servers: [ServerLoad]
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Node").frame(maxWidth: .infinity, alignment: .leading)
                Text("Reads").frame(width: 90, alignment: .trailing)
                Text("Writes").frame(width: 90, alignment: .trailing)
                Text("Role").frame(width: 90, alignment: .trailing)
            }.font(.caption.bold()).foregroundStyle(.secondary)
            Divider()
            ForEach(servers) { srv in
                HStack {
                    Text(srv.id).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Text("\(srv.reads)").frame(width: 90, alignment: .trailing).foregroundStyle(Theme.read)
                    Text("\(srv.writes)").frame(width: 90, alignment: .trailing).foregroundStyle(Theme.accent)
                    Text(role(srv)).frame(width: 90, alignment: .trailing).font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12, design: .monospaced)).padding(.vertical, 3)
                Divider().opacity(0.4)
            }
        }
    }
    private func role(_ s: ServerLoad) -> String {
        if s.writes > 0 && s.reads == 0 { return "primary" }
        if s.reads > 0 && s.writes == 0 { return "replica" }
        return "mixed"
    }
}

// MARK: - Pool health

struct PoolView: View {
    @EnvironmentObject var state: AppState
    private let cols = [GridItem(.adaptive(minimum: 250), spacing: 12)]

    var body: some View {
        let s = state.snapshot
        ScrollView {
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(s.connections) { c in ConnCard(conn: c) }
            }.padding(4)
            if s.connections.isEmpty {
                Text("No connections. Start the workload to spin up the pool.")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
        }
    }
}

struct ConnCard: View {
    var conn: ConnSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(Theme.color(for: conn.status)).frame(width: 9, height: 9)
                Text("Connection #\(conn.id)").font(.subheadline.bold())
                Spacer()
                Text(conn.status.rawValue).font(.caption).foregroundStyle(Theme.color(for: conn.status))
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                kv("ops", conn.ops.grouped)
                kv("errors", conn.errors.grouped, conn.errors > 0 ? Theme.bad : .primary)
                kv("reconnects", conn.reconnects.grouped, conn.reconnects > 0 ? Theme.warn : .primary)
                kv("last latency", conn.lastLatencyMs.ms())
                kv("write node", conn.lastWriteServer, Theme.accent)
                kv("read node", conn.lastReadServer, Theme.read)
            }
            if !conn.lastError.isEmpty {
                Text(conn.lastError).font(.caption2).foregroundStyle(Theme.bad)
                    .lineLimit(2).padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.color(for: conn.status).opacity(0.35)))
    }

    @ViewBuilder private func kv(_ k: String, _ v: String, _ color: Color = .primary) -> some View {
        GridRow {
            Text(k).font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .trailing).lineLimit(1)
        }
    }
}
