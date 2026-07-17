import SwiftUI
import TradingCore

/// Shared palette and small reusable UI pieces.
enum Theme {
    static let accent = Color(red: 0.16, green: 0.47, blue: 0.96)   // write / primary
    static let read = Color(red: 0.10, green: 0.68, blue: 0.55)     // read / replica
    static let good = Color(red: 0.18, green: 0.72, blue: 0.44)
    static let warn = Color(red: 0.95, green: 0.61, blue: 0.16)
    static let bad = Color(red: 0.90, green: 0.28, blue: 0.28)
    static let muted = Color.secondary

    static func color(for status: ConnStatus) -> Color {
        switch status {
        case .idle, .busy: return good
        case .connecting, .reconnecting: return warn
        case .error: return bad
        case .stopped: return muted
        }
    }
}

/// A compact KPI tile.
struct StatTile: View {
    var title: String
    var value: String
    var subtitle: String = ""
    var color: Color = .primary
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(color) }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(color).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06)))
    }
}

/// A titled card wrapper.
struct Card<Content: View>: View {
    var title: String
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                Text(title).font(.headline)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }
}

extension MetricsSnapshot {
    /// Recent buckets for plotting.
    func window(_ n: Int = 120) -> [SecondBucket] { Array(history.suffix(n)) }
}

extension Double {
    var compact: String {
        if self >= 1_000_000 { return String(format: "%.1fM", self / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fk", self / 1_000) }
        return String(format: "%.0f", self)
    }
    func ms(_ digits: Int = 1) -> String { String(format: "%.\(digits)f ms", self) }
}

extension Int {
    var grouped: String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}
