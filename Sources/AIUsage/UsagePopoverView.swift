import AIUsageCore
import AppKit
import SwiftUI

struct SparkPoint: Identifiable {
    let id: Date
    let ts: Date
    let fiveHour: Int?
    let oneWeek: Int?
    let extra: [String: Int]
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
            return SparkPoint(id: entry.ts, ts: entry.ts, fiveHour: w.fiveHour, oneWeek: w.oneWeek, extra: w.extra ?? [:])
        }
    }
}

struct UsagePopoverView: View {
    @ObservedObject var viewModel: PopoverViewModel

    static let preferredWidth: CGFloat = 380

    static func preferredContentSize(for snapshots: [UsageSnapshot], config: AppConfig = .default) -> CGSize {
        let enabledSnapshots = snapshots.filter(\.enabled)
        let width = preferredWidth
        if enabledSnapshots.isEmpty {
            return CGSize(width: width, height: 132)
        }

        // Per source: a fixed header/padding chunk (39) plus one row per
        // visible window. Each row is 32pt at the baseline (13pt) bar height,
        // growing 1:1 with any extra bar height — together these reproduce
        // the old flat "103 for 2 rows at 13pt" total exactly.
        let headerHeight: CGFloat = 41
        let footerHeight: CGFloat = 34
        let dividerHeight: CGFloat = 2 + CGFloat(max(0, enabledSnapshots.count - 1))
        let rowHeight: CGFloat = 32 + max(0, config.resolvedVisualBarHeight - 13)
        let providerBaseHeight: CGFloat = 39
        let failedExtraHeight: CGFloat = 28
        let failedCount = enabledSnapshots.filter { $0.status == .failed && $0.percentUsed == nil }.count

        let providersHeight = enabledSnapshots.reduce(CGFloat(0)) { total, snapshot in
            let source = config.sources.first(where: { $0.id == snapshot.sourceID })
            var visibleRows = (source?.resolvedShowFiveHourInPopover ?? true ? 1 : 0)
                + (source?.resolvedShowOneWeekInPopover ?? true ? 1 : 0)
            if source?.resolvedShowExtraInPopover ?? true {
                visibleRows += snapshot.extraWindows.count
            }
            return total + providerBaseHeight + CGFloat(visibleRows) * rowHeight
        }
        let contentHeight = headerHeight
            + footerHeight
            + dividerHeight
            + providersHeight
            + CGFloat(failedCount) * failedExtraHeight
        return CGSize(width: width, height: min(560, max(132, contentHeight)))
    }

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
            Divider()
            popoverFooter
        }
        .frame(
            width: Self.preferredWidth,
            height: Self.preferredContentSize(for: viewModel.snapshots, config: viewModel.config).height
        )
        // Opaque backing so the popover stays readable regardless of what's
        // behind it — NSPopover's own vibrant material otherwise lets bright
        // windows (e.g. a white browser) bleed through and wash out the text.
        .background(Color(nsColor: NSColor(calibratedRed: 30 / 255, green: 30 / 255, blue: 33 / 255, alpha: 1)))
        .environment(\.colorScheme, .dark)
        .onAppear {
            Task { await viewModel.loadHistory() }
        }
    }

    @ViewBuilder
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

    private var remainingCountdown: Bool {
        source?.resolvedRemainingCountdown(globalDefault: config.showsRemainingCountdown) ?? config.showsRemainingCountdown
    }

    private var fiveHourBurn: [BurnPoint] {
        burnPoints(
            duration: 5 * 3600,
            resetsAt: snapshot.fiveHour?.resetsAt,
            value: \.fiveHour
        )
    }

    private var oneWeekBurn: [BurnPoint] {
        burnPoints(
            duration: 7 * 24 * 3600,
            resetsAt: snapshot.oneWeek?.resetsAt,
            value: \.oneWeek
        )
    }

    private func burnPoints(
        duration: TimeInterval,
        resetsAt: Date?,
        value: KeyPath<SparkPoint, Int?>
    ) -> [BurnPoint] {
        burnPoints(duration: duration, resetsAt: resetsAt) { $0[keyPath: value] }
    }

    // Extra windows are keyed dynamically by model display name, so their
    // history has to be looked up by name rather than a fixed key path.
    private func extraBurnPoints(name: String, resetsAt: Date?) -> [BurnPoint] {
        burnPoints(duration: 7 * 24 * 3600, resetsAt: resetsAt) { $0.extra[name] }
    }

    private func burnPoints(
        duration: TimeInterval,
        resetsAt: Date?,
        value: (SparkPoint) -> Int?
    ) -> [BurnPoint] {
        let now = Date()
        let windowStart = resetsAt?.addingTimeInterval(-duration) ?? now.addingTimeInterval(-duration)
        let points = sparkPoints
            .filter { $0.ts >= windowStart && $0.ts <= now }
            .compactMap { sp in
                value(sp).map { BurnPoint(id: sp.ts, ts: sp.ts, pct: $0) }
            }
        return Self.trimToCurrentCycle(points)
    }

    /// Usage within a cycle only ever climbs, so a meaningful drop marks a
    /// reset. Keep only samples since the most recent reset — everything
    /// before it belongs to a previous cycle (or is stale/buggy data), so the
    /// window always starts fresh (≈100% remaining) instead of carrying it over.
    private static func trimToCurrentCycle(_ points: [BurnPoint], resetDrop: Int = 10) -> [BurnPoint] {
        guard points.count > 1 else { return points }
        var startIndex = 0
        for i in 1..<points.count where points[i - 1].pct - points[i].pct >= resetDrop {
            startIndex = i
        }
        return Array(points[startIndex...])
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

            if source?.resolvedShowFiveHourInPopover ?? true {
                WindowRow(
                    title: "5-hour",
                    window: snapshot.fiveHour,
                    isStale: isStale,
                    remainingCountdown: remainingCountdown,
                    burnPoints: fiveHourBurn,
                    sparklineDirection: config.sparklineDirection ?? .ascending,
                    barMode: config.resolvedVisualBarMode,
                    blockWidth: config.resolvedVisualBlockWidth,
                    historyStyle: config.resolvedVisualHistoryStyle,
                    barHeight: config.resolvedVisualBarHeight,
                    historyDarken: config.resolvedVisualHistoryDarken,
                    showPercent: source?.resolvedShowPercentInPopover ?? true,
                    percentFontSize: config.resolvedPopoverPercentFontSize,
                    percentFontWeight: config.popoverPercentFontWeight,
                    cycleDuration: 5 * 3600
                )
            }
            if source?.resolvedShowOneWeekInPopover ?? true {
                WindowRow(
                    title: "1-week",
                    window: snapshot.oneWeek,
                    isStale: isStale,
                    remainingCountdown: remainingCountdown,
                    burnPoints: oneWeekBurn,
                    sparklineDirection: config.sparklineDirection ?? .ascending,
                    barMode: config.resolvedVisualBarMode,
                    blockWidth: config.resolvedVisualBlockWidth,
                    historyStyle: config.resolvedVisualHistoryStyle,
                    barHeight: config.resolvedVisualBarHeight,
                    historyDarken: config.resolvedVisualHistoryDarken,
                    showPercent: source?.resolvedShowPercentInPopover ?? true,
                    percentFontSize: config.resolvedPopoverPercentFontSize,
                    percentFontWeight: config.popoverPercentFontWeight,
                    cycleDuration: 7 * 24 * 3600
                )
            }

            if source?.resolvedShowExtraInPopover ?? true {
                ForEach(snapshot.extraWindows.keys.sorted(), id: \.self) { name in
                    WindowRow(
                        title: name,
                        window: snapshot.extraWindows[name],
                        isStale: isStale,
                        remainingCountdown: remainingCountdown,
                        burnPoints: extraBurnPoints(name: name, resetsAt: snapshot.extraWindows[name]?.resetsAt),
                        sparklineDirection: config.sparklineDirection ?? .ascending,
                        barMode: config.resolvedVisualBarMode,
                        blockWidth: config.resolvedVisualBlockWidth,
                        historyStyle: config.resolvedVisualHistoryStyle,
                        barHeight: config.resolvedVisualBarHeight,
                        historyDarken: config.resolvedVisualHistoryDarken,
                        showPercent: source?.resolvedShowPercentInPopover ?? true,
                        percentFontSize: config.resolvedPopoverPercentFontSize,
                        percentFontWeight: config.popoverPercentFontWeight,
                        cycleDuration: 7 * 24 * 3600
                    )
                }
            }

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
        if let nsImage = ProviderIconRenderer.image(iconData: source?.iconData, iconName: source?.iconName, size: 14, color: .labelColor) {
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
    let sparklineDirection: SparklineDirection
    var barMode: VisualBarMode = .time
    var blockWidth: VisualBlockWidth = .medium
    var historyStyle: VisualHistoryStyle = .bars
    var barHeight: CGFloat = 30
    var historyDarken: Double = 10
    var showPercent: Bool = true
    var percentFontSize: CGFloat = 12
    var percentFontWeight: String? = nil
    var cycleDuration: TimeInterval = 5 * 3600

    /// Fraction of the cycle still remaining (1 right after a reset → 0 at reset).
    private func cycleRemainingFrac(for window: ProviderUsageWindow) -> CGFloat {
        guard let resetsAt = window.resetsAt, cycleDuration > 0 else { return 0 }
        let remaining = resetsAt.timeIntervalSinceNow
        return CGFloat(max(0, min(1, remaining / cycleDuration)))
    }

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

                    VisualBurnBarView(
                        burnPoints: burnPoints,
                        currentPct: window.percentUsed,
                        remainingCountdown: remainingCountdown,
                        color: color,
                        sparklineDirection: sparklineDirection,
                        barMode: barMode,
                        blockWidth: blockWidth,
                        historyStyle: historyStyle,
                        barHeight: barHeight,
                        historyDarken: historyDarken,
                        cycleRemainingFrac: cycleRemainingFrac(for: window)
                    )

                    if showPercent {
                        Text("\(displayPct)%")
                            .font(.system(size: percentFontSize, weight: resolvedPercentFontWeight(from: percentFontWeight), design: .monospaced).monospacedDigit())
                            .foregroundStyle(isStale ? .secondary : .primary)
                            .frame(width: 30, alignment: .trailing)
                    }
                } else {
                    Capsule().fill(.secondary.opacity(0.09)).frame(height: barHeight)
                    if showPercent {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                            .frame(width: 30, alignment: .trailing)
                    }
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

func resolvedPercentFontWeight(from raw: String?) -> Font.Weight {
    switch raw {
    case "light": .light
    case "regular": .regular
    case "medium": .medium
    case "bold": .bold
    default: .semibold
    }
}

struct VisualBurnBarView: View {
    let burnPoints: [BurnPoint]
    let currentPct: Int
    let remainingCountdown: Bool
    let color: Color
    var sparklineDirection: SparklineDirection = .ascending
    var barMode: VisualBarMode = .time
    var blockWidth: VisualBlockWidth = .medium
    var historyStyle: VisualHistoryStyle = .bars
    var barHeight: CGFloat = 30
    var historyDarken: Double = 10
    var cycleRemainingFrac: CGFloat = 0

    /// 1.0 = full brightness, lower = darker. Applied to the history
    /// bars/line so they read as a step back from the remaining-time fill.
    private var historyOpacityScale: CGFloat {
        CGFloat(1 - min(100, max(0, historyDarken)) / 100)
    }

    @State private var hoveredPoint: BurnPoint? = nil
    @State private var hoverX: CGFloat = 0

    private let fillRadius: CGFloat = 4
    // Includes the date, not just the time — a 1-week or extra window's
    // history spans multiple days, so "14:32" alone is ambiguous about which day.
    private static let tooltipFmt: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM, HH:mm")
        return f
    }()

    private var fillGradient: LinearGradient {
        LinearGradient(colors: [color, color.opacity(0.82)], startPoint: .top, endPoint: .bottom)
    }

    // Same down-sampling used for drawing, so hit-testing lines up exactly
    // with what's on screen (an exact-index match instead of a fuzzy nearest-
    // timestamp search, which used to miss most of the down-sampled bars).
    private func displayPoints(width: CGFloat) -> [BurnPoint] {
        sampledForDisplay(burnPoints, width: width, targetWidth: blockWidth.metrics.width, gap: blockWidth.metrics.gap)
    }

    private func barWidth(forCount n: Int, width: CGFloat, gap: CGFloat) -> CGFloat {
        guard n > 0 else { return 0 }
        return max(2, (width - CGFloat(n - 1) * gap) / CGFloat(n))
    }

    private func nearestIndex(at x: CGFloat, count: Int, barWidth: CGFloat, gap: CGFloat, width: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        var bestIndex = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in 0..<count {
            let bx = width - CGFloat(i + 1) * barWidth - CGFloat(i) * gap
            let dist = abs((bx + barWidth / 2) - x)
            if dist < bestDist { bestDist = dist; bestIndex = i }
        }
        return bestIndex
    }

    // The current level as a fraction — matches the % number shown in the row.
    // (86% tall when 86% is left, in remaining-countdown mode.)
    private var currentLevelFrac: CGFloat {
        CGFloat(max(0, min(100, remainingCountdown ? 100 - currentPct : currentPct))) / 100
    }

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height
            let timeFrac = max(0, min(1, cycleRemainingFrac))
            let fillW = timeFrac * W
            // History blocks sit in the elapsed region (right of the fill).
            let region = (offX: fillW, width: W - fillW)

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color(nsColor: NSColor(calibratedWhite: 1, alpha: 0.055)))

                // Solid fill — width = cycle time remaining.
                if fillW > 0 {
                    switch barMode {
                    case .time:
                        RoundedRectangle(cornerRadius: fillRadius)
                            .fill(fillGradient)
                            .frame(width: fillW, height: H)
                    case .timeLevel:
                        // Height = current level (the last update block).
                        let fh = max(4, currentLevelFrac * H)
                        RoundedRectangle(cornerRadius: min(fillRadius, fh / 2))
                            .fill(fillGradient)
                            .frame(width: fillW, height: fh)
                            .frame(width: W, height: H, alignment: .bottomLeading)
                    }
                }

                // Session history in the elapsed region — blocks or a line.
                if burnPoints.count >= 2, region.width > 8 {
                    let col = color, hv = hoveredPoint, dir = sparklineDirection, darken = historyOpacityScale
                    switch historyStyle {
                    case .bars:
                        let pts = displayPoints(width: region.width)
                        let gap = blockWidth.metrics.gap
                        Canvas { ctx, size in
                            drawVisualBars(ctx: ctx, size: size, points: pts, color: col, direction: dir, hovered: hv, gap: gap, opacityScale: darken)
                        }
                        .frame(width: region.width, height: H)
                        .offset(x: region.offX)
                    case .line:
                        let pts = burnPoints
                        Canvas { ctx, size in
                            drawCurve(ctx: ctx, size: size, points: pts, color: col, direction: dir, hovered: hv, opacityScale: darken)
                        }
                        .frame(width: region.width, height: H)
                        .offset(x: region.offX)
                    }
                }

                // Hover crosshair
                if hoveredPoint != nil {
                    Rectangle()
                        .fill(Color.primary.opacity(0.16))
                        .frame(width: 1, height: H)
                        .offset(x: hoverX - 0.5)
                }
            }
            .clipShape(Capsule())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    hoverX = loc.x
                    switch historyStyle {
                    case .bars:
                        let localX = loc.x - region.offX
                        let pts = displayPoints(width: region.width)
                        let gap = blockWidth.metrics.gap
                        let bw = barWidth(forCount: pts.count, width: region.width, gap: gap)
                        if (0...region.width).contains(localX), !pts.isEmpty, bw > 0,
                           let idx = nearestIndex(at: localX, count: pts.count, barWidth: bw, gap: gap, width: region.width) {
                            hoveredPoint = pts[idx]
                        } else {
                            hoveredPoint = nil
                        }
                    case .line:
                        let relX = region.width > 0 ? (loc.x - region.offX) / region.width : -1
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
                    }
                case .ended:
                    hoveredPoint = nil
                }
            }
        }
        .frame(height: barHeight)
        .overlay(alignment: .topLeading) {
            if let pt = hoveredPoint {
                let displayPct = remainingCountdown ? 100 - pt.pct : pt.pct
                Text("\(Self.tooltipFmt.string(from: pt.ts))  \(displayPct)%")
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: max(2, hoverX - 26), y: -(barHeight + 6))
                    .fixedSize()
                    .allowsHitTesting(false)
            }
        }
    }
}

// Free functions so Canvas closures capture only plain values (no self)

private func sparklineY(pct: Int, height: CGFloat, direction: SparklineDirection) -> CGFloat {
    let frac = CGFloat(pct) / 100.0
    return direction == .descending ? height * frac : height * (1.0 - frac)
}

private func sparklineBaseline(height: CGFloat, direction: SparklineDirection) -> CGFloat {
    direction == .descending ? 0 : height
}

private func sparklineX(ts: Date, t0: Date, dt: TimeInterval, width: CGFloat) -> CGFloat {
    CGFloat(1.0 - ts.timeIntervalSince(t0) / dt) * width
}

private func drawCurve(
    ctx: GraphicsContext, size: CGSize,
    points: [BurnPoint], color: Color,
    direction: SparklineDirection, hovered: BurnPoint?,
    opacityScale: CGFloat = 1
) {
    guard points.count >= 2 else { return }
    let t0 = points.first!.ts
    let dt = points.last!.ts.timeIntervalSince(t0)
    guard dt > 0 else { return }

    let pts: [CGPoint] = points.map { bp in
        CGPoint(
            x: sparklineX(ts: bp.ts, t0: t0, dt: dt, width: size.width),
            y: sparklineY(pct: bp.pct, height: size.height, direction: direction)
        )
    }
    let baseline = sparklineBaseline(height: size.height, direction: direction)

    var area = Path()
    area.move(to: CGPoint(x: pts[0].x, y: baseline))
    pts.forEach { area.addLine(to: $0) }
    area.addLine(to: CGPoint(x: pts.last!.x, y: baseline))
    area.closeSubpath()
    ctx.fill(area, with: .color(color.opacity(0.07 * opacityScale)))

    var line = Path()
    line.move(to: pts[0])
    pts.dropFirst().forEach { line.addLine(to: $0) }
    ctx.stroke(line, with: .color(color.opacity(0.8 * opacityScale)), lineWidth: 1.5)

    if let hv = hovered {
        let x = sparklineX(ts: hv.ts, t0: t0, dt: dt, width: size.width)
        let y = sparklineY(pct: hv.pct, height: size.height, direction: direction)
        let r: CGFloat = 2.5
        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(color))
    }
}

/// Down-samples to at most one point per `targetWidth + gap` slot, evenly
/// across the series, keeping chronological order (oldest first). Both the
/// Canvas drawing and the hover hit-test call this with identical arguments,
/// so what's on screen and what the mouse can target always match exactly.
private func sampledForDisplay(_ points: [BurnPoint], width: CGFloat, targetWidth: CGFloat, gap: CGFloat) -> [BurnPoint] {
    guard points.count > 1, width > 2 else { return points }
    let slot = targetWidth + gap
    let count = max(2, min(points.count, Int(width / slot)))
    guard points.count > count else { return points }
    return (0..<count).map { i in
        points[Int((Double(i) / Double(count - 1)) * Double(points.count - 1))]
    }
}

// Block sparkline for the tall visual bar: the session history as rounded
// vertical bars inside the remaining region, newest at the left (same
// orientation and value mapping as the compact sparkline). `points` is
// expected to already be down-sampled via sampledForDisplay.
private func drawVisualBars(
    ctx: GraphicsContext, size: CGSize,
    points: [BurnPoint], color: Color,
    direction: SparklineDirection, hovered: BurnPoint?,
    gap: CGFloat, opacityScale: CGFloat = 1
) {
    guard points.count >= 1, size.width > 2 else { return }
    let n = points.count
    let barWidth = max(2, (size.width - CGFloat(n - 1) * gap) / CGFloat(n))
    let radius = min(barWidth / 2, 2)

    for (index, point) in points.enumerated() {
        let displayPct = direction == .descending ? 100 - point.pct : point.pct
        let clamped = CGFloat(max(0, min(100, displayPct)))
        let barHeight = max(3, size.height * clamped / 100)
        // Newest sample sits at the left edge; grows up from the bottom.
        let x = size.width - CGFloat(index + 1) * barWidth - CGFloat(index) * gap
        let y = size.height - barHeight
        // Points are drawn straight from displayPoints(width:), the same
        // array the hover hit-test indexes into — exact equality is safe.
        let isHovered = hovered.map { $0.ts == point.ts } ?? false
        // Full brightness at 0.95/0.8, scaled down by the darken setting
        // (defaults to ~10% darker than the remaining-time fill).
        let baseOpacity: CGFloat = index == n - 1 ? 0.95 : 0.8
        let opacity = isHovered ? 1.0 : baseOpacity * opacityScale
        ctx.fill(
            Path(roundedRect: CGRect(x: x, y: y, width: barWidth, height: barHeight), cornerRadius: radius),
            with: .color(color.opacity(opacity))
        )
    }
}
