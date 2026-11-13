#if canImport(SwiftUI)
import SwiftUI

#if canImport(Charts)
import Charts
#endif

/// Real-time 60-second rolling bandwidth speed chart.
///
/// **Features:**
/// - Uses Apple's modern Swift Charts framework on iOS 16+ / macOS 13+.
/// - Provides a high-fidelity custom `Path` / `Canvas` bezier fallback for iOS 15.
/// - Renders separate, visually distinct series for Download (Blue) and Upload (Green).
/// - Includes readable speed labels (Y-axis) and time-axis markers (-60s to Now).
/// - Displays instantaneous and peak throughput indicators.
public struct SpeedChartView: View {
    public let history: [BandwidthSample]
    public let currentDownloadSpeed: Double
    public let currentUploadSpeed: Double
    public let peakDownloadSpeed: Double
    public let peakUploadSpeed: Double

    public init(
        history: [BandwidthSample],
        currentDownloadSpeed: Double,
        currentUploadSpeed: Double,
        peakDownloadSpeed: Double,
        peakUploadSpeed: Double
    ) {
        self.history = history
        self.currentDownloadSpeed = currentDownloadSpeed
        self.currentUploadSpeed = currentUploadSpeed
        self.peakDownloadSpeed = peakDownloadSpeed
        self.peakUploadSpeed = peakUploadSpeed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            metricsHeader

            #if canImport(Charts)
            if #available(iOS 16.0, macOS 13.0, *) {
                SwiftChartsSpeedGraph(history: history)
                    .frame(height: 130)
            } else {
                CustomPathSpeedGraph(history: history)
                    .frame(height: 130)
            }
            #else
            CustomPathSpeedGraph(history: history)
                .frame(height: 130)
            #endif

            timeAxisLabels
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
    }

    // MARK: - Header Metrics

    private var metricsHeader: some View {
        HStack(alignment: .top) {
            // Download Speed
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 1) {
                    Text("↓ \(UIFormatters.formatSpeed(currentDownloadSpeed))")
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)

                    Text("Peak: \(UIFormatters.formatSpeed(peakDownloadSpeed))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Upload Speed
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 16))

                VStack(alignment: .trailing, spacing: 1) {
                    Text("↑ \(UIFormatters.formatSpeed(currentUploadSpeed))")
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)

                    Text("Peak: \(UIFormatters.formatSpeed(peakUploadSpeed))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Time Axis Labels

    private var timeAxisLabels: some View {
        HStack {
            Text("-60s")
            Spacer()
            Text("-45s")
            Spacer()
            Text("-30s")
            Spacer()
            Text("-15s")
            Spacer()
            Text("Now")
        }
        .font(.system(size: 9))
        .foregroundColor(.secondary)
        .padding(.horizontal, 4)
    }
}

// MARK: - Swift Charts Graph (iOS 16+)

#if canImport(Charts)
@available(iOS 16.0, macOS 13.0, *)
private struct SwiftChartsSpeedGraph: View {
    let history: [BandwidthSample]

    private struct ChartDataPoint: Identifiable {
        let id: String
        let relativeSeconds: Double // -60 to 0
        let speedBytesPerSecond: Double
        let seriesName: String
    }

    private var chartPoints: [ChartDataPoint] {
        guard !history.isEmpty else { return [] }
        let now = history.last?.timestamp ?? Date().timeIntervalSince1970
        var points: [ChartDataPoint] = []

        for sample in history {
            let offset = max(-60.0, min(0.0, sample.timestamp - now))
            points.append(ChartDataPoint(
                id: "\(sample.timestamp)-dl",
                relativeSeconds: offset,
                speedBytesPerSecond: sample.downloadBytesPerSecond,
                seriesName: "Download"
            ))
            points.append(ChartDataPoint(
                id: "\(sample.timestamp)-ul",
                relativeSeconds: offset,
                speedBytesPerSecond: sample.uploadBytesPerSecond,
                seriesName: "Upload"
            ))
        }

        // If history has fewer than 2 points, add a starting baseline at -60s so axes render stably
        if history.count < 2 {
            points.insert(ChartDataPoint(id: "base-dl", relativeSeconds: -60.0, speedBytesPerSecond: 0, seriesName: "Download"), at: 0)
            points.insert(ChartDataPoint(id: "base-ul", relativeSeconds: -60.0, speedBytesPerSecond: 0, seriesName: "Upload"), at: 1)
        }

        return points
    }

    var body: some View {
        Chart(chartPoints) { point in
            LineMark(
                x: .value("Seconds Ago", point.relativeSeconds),
                y: .value("Speed", point.speedBytesPerSecond)
            )
            .foregroundStyle(by: .value("Series", point.seriesName))
            .interpolationMethod(.monotone)

            AreaMark(
                x: .value("Seconds Ago", point.relativeSeconds),
                y: .value("Speed", point.speedBytesPerSecond)
            )
            .foregroundStyle(by: .value("Series", point.seriesName))
            .opacity(0.12)
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale([
            "Download": Color.blue,
            "Upload": Color.green
        ])
        .chartXScale(domain: -60...0)
        .chartXAxis {
            AxisMarks(values: [-60, -45, -30, -15, 0]) { value in
                AxisGridLine()
                AxisTick()
                if let sec = value.as(Double.self) {
                    AxisValueLabel {
                        Text(sec == 0 ? "Now" : "\(Int(sec))s")
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                if let spd = value.as(Double.self) {
                    AxisValueLabel {
                        Text(UIFormatters.formatSpeed(spd))
                            .font(.system(size: 8))
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }
}
#endif

// MARK: - Custom Path Fallback Graph (iOS 15 Fallback)

private struct CustomPathSpeedGraph: View {
    let history: [BandwidthSample]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            let now = history.last?.timestamp ?? Date().timeIntervalSince1970
            let maxRecorded = history.flatMap { [$0.downloadBytesPerSecond, $0.uploadBytesPerSecond] }.max() ?? 0.0
            let ceilingSpeed = max(1024 * 64, maxRecorded * 1.15) // Clean headroom

            ZStack(alignment: .topTrailing) {
                // Background grid lines (100%, 66%, 33%, 0%)
                VStack(spacing: 0) {
                    Divider().background(Color.secondary.opacity(0.25))
                    Spacer()
                    Divider().background(Color.secondary.opacity(0.15))
                    Spacer()
                    Divider().background(Color.secondary.opacity(0.15))
                    Spacer()
                    Divider().background(Color.secondary.opacity(0.35))
                }

                // Y-Axis speed labels
                VStack(alignment: .trailing) {
                    Text(UIFormatters.formatSpeed(ceilingSpeed))
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(UIFormatters.formatSpeed(ceilingSpeed * 0.5))
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("0 B/s")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
                .padding(.trailing, 2)

                if history.count >= 2 {
                    // Upload area & stroke (Green)
                    path(for: \.uploadBytesPerSecond, width: w, height: h, now: now, ceilingSpeed: ceilingSpeed, isClosed: true)
                        .fill(LinearGradient(
                            colors: [Color.green.opacity(0.20), Color.green.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))

                    path(for: \.uploadBytesPerSecond, width: w, height: h, now: now, ceilingSpeed: ceilingSpeed, isClosed: false)
                        .stroke(Color.green, lineWidth: 1.5)

                    // Download area & stroke (Blue)
                    path(for: \.downloadBytesPerSecond, width: w, height: h, now: now, ceilingSpeed: ceilingSpeed, isClosed: true)
                        .fill(LinearGradient(
                            colors: [Color.blue.opacity(0.22), Color.blue.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))

                    path(for: \.downloadBytesPerSecond, width: w, height: h, now: now, ceilingSpeed: ceilingSpeed, isClosed: false)
                        .stroke(Color.blue, lineWidth: 2.0)
                } else {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("Accumulating 60s bandwidth history...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func path(
        for keyPath: KeyPath<BandwidthSample, Double>,
        width: CGFloat,
        height: CGFloat,
        now: TimeInterval,
        ceilingSpeed: Double,
        isClosed: Bool
    ) -> Path {
        var p = Path()
        guard !history.isEmpty else { return p }

        let window: Double = 60.0
        var points: [CGPoint] = []

        for sample in history {
            let age = max(0.0, min(window, now - sample.timestamp))
            let xFrac = 1.0 - (age / window) // 0.0 (60s ago) to 1.0 (now)
            let x = CGFloat(xFrac) * width

            let speed = sample[keyPath: keyPath]
            let yFrac = min(1.0, max(0.0, speed / ceilingSpeed))
            let y = (1.0 - CGFloat(yFrac)) * height

            points.append(CGPoint(x: x, y: y))
        }

        guard let first = points.first else { return p }
        p.move(to: first)
        for pt in points.dropFirst() {
            p.addLine(to: pt)
        }

        if isClosed, let last = points.last {
            p.addLine(to: CGPoint(x: last.x, y: height))
            p.addLine(to: CGPoint(x: first.x, y: height))
            p.closeSubpath()
        }

        return p
    }
}
#endif

