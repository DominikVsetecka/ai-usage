import AIUsageCore
import AppKit
import SwiftUI

struct SparkPoint: Identifiable {
    let id: Date
    let ts: Date
    let fiveHour: Int?
    let oneWeek: Int?
}

struct BurnPoint: Identifiable {
    let id: Date
    let ts: Date
    let pct: Int
}

@MainActor
final class PopoverViewModel: ObservableObject {
    @Published var snapshots: [UsageSnapshot] = []
    @Published var config: AppConfig
    @Published var isRefreshing = false
    @Published var sparkData: [UsageHistoryEntry] = []

    var historyStore: UsageHistoryStore?
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(config: AppConfig) {
        self.config = config
    }

    func loadHistory() async {
        guard let store = historyStore else { return }
        sparkData = await store.load(days: 7)
    }

    func sparkPoints(for sourceID: String) -> [SparkPoint] {
        sparkData.compactMap { entry in
            guard let w = entry.sources[sourceID] else { return nil }
            return SparkPoint(id: entry.ts, ts: entry.ts, fiveHour: w.fiveHour, oneWeek: w.oneWeek)
        }
    }
}

struct UsagePopoverView: View {
    @ObservedObject var viewModel: PopoverViewModel

    private var enabledSnapshots: [UsageSnapshot] {
        viewModel.snapshots.filter(\.enabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            popoverHeader
            Divider()
            if enabledSnapshots.isEmpty {
                Text("No sources enabled")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(enabledSnapshots.enumerated()), id: \.element.sourceID) { index, snapshot in
                            let source = viewModel.config.sources.first(where: { $0.id == snapshot.sourceID })
                            ProviderDetailSection(
                                snapshot: snapshot,
                                source: source,
                                config: viewModel.config,
                                sparkPoints: viewModel.sparkPoints(for: snapshot.sourceID)
                            )
                            if index < enabledSnapshots.count - 1 {
                                Divider().padding(.horizontal, 14)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 520)
            }
            Divider()
            popoverFooter
        }
        .frame(width: 380)
        .onAppear {
            Task { await viewModel.loadHistory() }
        }
    }

    private var popoverHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tint)
            Text("AI Usage")
                .font(.headline)
            Spacer()
            if viewModel.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    viewModel.onRefresh?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh Now")
            }
            Button {
                viewModel.onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings…")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var popoverFooter: some View {
        HStack {
            Spacer()
            Button("Quit AI Usage") {
                viewModel.onQuit?()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct ProviderDetailSection: View {
    let snapshot: UsageSnapshot
    let source: SourceConfig?
    let config: AppConfig
    let sparkPoints: [SparkPoint]

    private var isStale: Bool { snapshot.status == .failed && snapshot.percentUsed != nil }
    private var isFailed: Bool { snapshot.status == .failed && snapshot.percentUsed == nil }

    private var fiveHourBurn: [BurnPoint] {
        let cutoff = Date().addingTimeInterval(-5 * 3600)
        return sparkPoints
            .filter { $0.ts >= cutoff }
            .compactMap { sp in sp.fiveHour.map { BurnPoint(id: sp.ts, ts: sp.ts, pct: $0) } }
    }

    private var oneWeekBurn: [BurnPoint] {
        sparkPoints.compactMap { sp in sp.oneWeek.map { BurnPoint(id: sp.ts, ts: sp.ts, pct: $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                providerIcon
                Text(snapshot.label)
                    .font(.subheadline.weight(.medium))
                Spacer()
                statusBadge
            }

            WindowRow(
                title: "5-hour",
                window: snapshot.fiveHour,
                isStale: isStale,
                remainingCountdown: config.showsRemainingCountdown,
                burnPoints: fiveHourBurn
            )
            WindowRow(
                title: "1-week",
                window: snapshot.oneWeek,
                isStale: isStale,
                remainingCountdown: config.showsRemainingCountdown,
                burnPoints: oneWeekBurn
            )

            if let error = snapshot.errorMessage, isFailed {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.75))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let iconName = source?.iconName,
           let nsImage = ProviderIconRenderer.image(named: iconName, size: 14, color: .labelColor) {
            Image(nsImage: nsImage)
                .interpolation(.high)
                .antialiased(true)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isStale {
            HStack(spacing: 3) {
                Image(systemName: "clock.badge.exclamationmark").font(.caption2)
                if let updatedAt = snapshot.updatedAt {
                    Text(UsageFormatter.shortTime(updatedAt)).font(.caption2)
                }
            }
            .foregroundStyle(.secondary)
        } else if snapshot.status == .idle {
            Text("loading…").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct WindowRow: View {
    let title: String
    let window: ProviderUsageWindow?
    let isStale: Bool
    let remainingCountdown: Bool
    let burnPoints: [BurnPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)

                if let window {
                    let displayPct = remainingCountdown ? max(0, 100 - window.percentUsed) : window.percentUsed
                    let color = barColor(pct: window.percentUsed)

                    BurnBarView(
                        burnPoints: burnPoints,
                        currentPct: window.percentUsed,
                        remainingCountdown: remainingCountdown,
                        color: color
                    )

                    Text("\(displayPct)%")
                        .font(.system(.caption, design: .monospaced).monospacedDigit())
                        .foregroundStyle(isStale ? .secondary : .primary)
                        .frame(width: 30, alignment: .trailing)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(height: 9)
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                        .frame(width: 30, alignment: .trailing)
                }
            }

            if let window {
                Text(resetLabel(for: window))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 54)
            }
        }
        .opacity(isStale ? 0.6 : 1)
    }

    private func resetLabel(for window: ProviderUsageWindow) -> String {
        if let at = window.resetsAt {
            let remaining = at.timeIntervalSinceNow
            if remaining > 0 {
                let h = Int(remaining) / 3600
                let m = (Int(remaining) % 3600) / 60
                if h > 0 {
                    return "Resets in \(h) hr \(m) min"
                } else if m > 0 {
                    return "Resets in \(m) min"
                } else {
                    return "Resets in <1 min"
                }
            }
            return window.resetDescription ?? ""
        }
        return window.resetDescription ?? ""
    }

    private func barColor(pct: Int) -> Color {
        let remaining = 100 - min(100, max(0, pct))
        return Color(hue: Double(remaining) / 300, saturation: 0.82, brightness: 0.88)
    }
}

private struct BurnBarView: View {
    let burnPoints: [BurnPoint]
    let currentPct: Int
    let remainingCountdown: Bool
    let color: Color

    @State private var hoveredPoint: BurnPoint? = nil
    @State private var hoverX: CGFloat = 0

    private static let barHeight: CGFloat = 13
    private static let radius:    CGFloat = 6.5  // capsule
    private static let tooltipFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            let fillFrac = CGFloat(max(0, min(100, remainingCountdown ? 100 - currentPct : currentPct))) / 100
            let fillW = W * fillFrac
            let sparkOffX: CGFloat = remainingCountdown ? fillW : 0
            let sparkW: CGFloat = remainingCountdown ? (W - fillW) : fillW

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: Self.radius)
                    .fill(.secondary.opacity(0.09))

                // Solid fill — capsule pill, sharp right edge clipped by outer shape
                if fillW > 0 {
                    RoundedRectangle(cornerRadius: Self.radius)
                        .fill(color)
                        .frame(width: fillW, height: H)
                }

                // Burn sparkline
                if burnPoints.count >= 2, sparkW > 8 {
                    let pts = burnPoints, col = color, hv = hoveredPoint
                    Canvas { ctx, size in
                        drawCurve(ctx: ctx, size: size, points: pts, color: col, inRight: remainingCountdown, hovered: hv)
                    }
                    .frame(width: sparkW, height: H)
                    .offset(x: sparkOffX)
                }

                // Hover crosshair
                if hoveredPoint != nil {
                    Rectangle()
                        .fill(Color.primary.opacity(0.13))
                        .frame(width: 1, height: H)
                        .offset(x: hoverX - 0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.radius))
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    hoverX = loc.x
                    let relX = sparkW > 0 ? (loc.x - sparkOffX) / sparkW : -1
                    if (0...1).contains(relX), !burnPoints.isEmpty {
                        let t0 = burnPoints.first!.ts
                        let dt = burnPoints.last!.ts.timeIntervalSince(t0)
                        // x-axis is flipped: relX=0 → left → now (newest), relX=1 → right → oldest
                        let target = t0.addingTimeInterval(dt * Double(1.0 - relX))
                        hoveredPoint = burnPoints.min(by: {
                            abs($0.ts.timeIntervalSince(target)) < abs($1.ts.timeIntervalSince(target))
                        })
                    } else {
                        hoveredPoint = nil
                    }
                case .ended:
                    hoveredPoint = nil
                }
            }
        }
        .frame(height: Self.barHeight)
        .overlay(alignment: .topLeading) {
            if let pt = hoveredPoint {
                let displayPct = remainingCountdown ? 100 - pt.pct : pt.pct
                Text("\(Self.tooltipFmt.string(from: pt.ts))  \(displayPct)%")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: max(2, hoverX - 26), y: -(Self.barHeight + 6))
                    .fixedSize()
                    .allowsHitTesting(false)
            }
        }
    }
}

// Free function so Canvas closure captures only plain values (no self)
private func drawCurve(
    ctx: GraphicsContext, size: CGSize,
    points: [BurnPoint], color: Color,
    inRight: Bool, hovered: BurnPoint?
) {
    guard points.count >= 2 else { return }
    let t0 = points.first!.ts
    let dt = points.last!.ts.timeIntervalSince(t0)
    guard dt > 0 else { return }

    func toPoint(_ bp: BurnPoint) -> CGPoint {
        let x = CGFloat(1.0 - bp.ts.timeIntervalSince(t0) / dt) * size.width
        // Y: 0% used → bottom, 100% used → top (higher curve = faster burn)
        let y = size.height * (1.0 - CGFloat(bp.pct) / 100.0)
        return CGPoint(x: x, y: y)
    }

    let pts = points.map(toPoint)

    // Very subtle area — just enough to anchor the line visually
    var area = Path()
    area.move(to: CGPoint(x: pts[0].x, y: size.height))
    pts.forEach { area.addLine(to: $0) }
    area.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
    area.closeSubpath()
    ctx.fill(area, with: .color(color.opacity(0.07)))

    // Sharp line — straight segments make usage spikes clearly visible
    var line = Path()
    line.move(to: pts[0])
    pts.dropFirst().forEach { line.addLine(to: $0) }
    ctx.stroke(line, with: .color(color.opacity(0.72)), lineWidth: 1.5)

    // Hover dot — solid, stands out against the line
    if let hv = hovered {
        let x = CGFloat(1.0 - hv.ts.timeIntervalSince(t0) / dt) * size.width
        let y = size.height * (1.0 - CGFloat(hv.pct) / 100.0)
        let r: CGFloat = 2.5
        ctx.fill(
            Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
            with: .color(color)
        )
    }
}
