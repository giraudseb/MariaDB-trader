import SwiftUI
import TradingCore

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showConfig = false

    var body: some View {
        VStack(spacing: 0) {
            ControlBar(showConfig: $showConfig)
            Divider()
            TabView {
                OverviewView().tabItem { Label("Overview", systemImage: "gauge.with.dots.needle.67percent") }
                ThroughputView().tabItem { Label("Throughput & Latency", systemImage: "chart.xyaxis.line") }
                FailoverView().tabItem { Label("Failover", systemImage: "arrow.triangle.2.circlepath") }
                SplitView().tabItem { Label("Read/Write Split", systemImage: "arrow.left.arrow.right") }
                PoolView().tabItem { Label("Pool Health", systemImage: "server.rack") }
            }
            .padding(8)
            Divider()
            LogStrip()
        }
        .sheet(isPresented: $showConfig) { ConfigSheet() }
    }
}

// MARK: - Control bar

struct ControlBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showConfig: Bool

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(state.isRunning ? (state.isPaused ? Theme.warn : Theme.good) : Theme.muted)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MariaDB-Trader").font(.headline)
                    Text("\(state.host):\(state.port) · \(state.database)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Divider().frame(height: 30)

            // Live tuning
            VStack(alignment: .leading, spacing: 2) {
                Text("Read ratio: \(Int(state.readRatio * 100))% reads")
                    .font(.caption2).foregroundStyle(.secondary)
                Slider(value: $state.readRatio, in: 0...1) { _ in state.applyLiveTuning() }
                    .frame(width: 160)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.ratePerWorker == 0 ? "Rate: unthrottled"
                     : "Rate: \(Int(state.ratePerWorker))/wkr·s")
                    .font(.caption2).foregroundStyle(.secondary)
                Slider(value: $state.ratePerWorker, in: 0...500, step: 10) { _ in state.applyLiveTuning() }
                    .frame(width: 140)
            }

            Spacer()

            Button { showConfig = true } label: { Label("Config", systemImage: "slider.horizontal.3") }
                .disabled(state.isRunning)

            if state.isRunning {
                Button { state.togglePause() } label: {
                    Label(state.isPaused ? "Resume" : "Pause",
                          systemImage: state.isPaused ? "play.fill" : "pause.fill")
                }
                Button(role: .destructive) { state.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }.tint(Theme.bad)
            } else {
                Button { state.start() } label: {
                    Label("Start workload", systemImage: "play.fill")
                }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Config sheet

struct ConfigSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connection & Workload").font(.title2).bold()
            Text("Point at your MaxScale listener. Reads route to replicas, writes to the primary.")
                .font(.caption).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                row("Host", TextField("127.0.0.1", text: $state.host))
                row("Port", TextField("4006", text: $state.port))
                row("User", TextField("app", text: $state.user))
                row("Password", SecureField("", text: $state.password))
                row("Database", TextField("trading", text: $state.database))
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                labeledSlider("Workers (connections)", value: $state.workers,
                              range: 1...64, step: 1, text: "\(Int(state.workers))")
                labeledSlider("Seed accounts", value: $state.accounts,
                              range: 50...5000, step: 50, text: "\(Int(state.accounts))")
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460)
    }

    @ViewBuilder private func row(_ label: String, _ field: some View) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            field.textFieldStyle(.roundedBorder).frame(width: 260)
        }
    }

    @ViewBuilder private func labeledSlider(_ label: String, value: Binding<Double>,
                                            range: ClosedRange<Double>, step: Double,
                                            text: String) -> some View {
        HStack {
            Text(label).frame(width: 170, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(text).monospacedDigit().frame(width: 50, alignment: .trailing)
        }
    }
}

// MARK: - Log strip

struct LogStrip: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(state.log.enumerated()), id: \.offset) { idx, line in
                        Text(line).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).id(idx)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .frame(height: 96)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            .onChange(of: state.log.count) { _, c in
                if c > 0 { withAnimation { proxy.scrollTo(c - 1, anchor: .bottom) } }
            }
        }
    }
}
