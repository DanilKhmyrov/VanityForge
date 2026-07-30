import Charts
import SwiftUI

struct SpeedChartView: View {
    @Environment(SessionViewModel.self) private var session

    private var accent: Color {
        session.orderedNetworks.first.map(NetworkVisual.accent(for:)) ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.t(.speedChartHeader))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)

            if session.speedHistory.count < 2 {
                emptyState
            } else {
                chart
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedGlass(accent: accent, cornerRadius: 14, intensity: 0.8)
        .animation(.easeOut(duration: 0.35), value: session.speedHistory.count < 2)
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            Text(session.t(.speedChartEmpty))
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(height: 120)
    }

    /// Явный диапазон оси X по фактическим данным (а не auto-domain у Charts):
    /// при непрерывно скользящем окне auto-domain у Charts анимируется вслед
    /// за данными и никогда не успевает "догнать" их — из-за этого график
    /// визуально сжимался в правый край с пустым местом слева.
    private var xDomain: ClosedRange<Double> {
        let values = session.speedHistory.map(\.elapsed)
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        return lo < hi ? lo...hi : lo...(lo + 1)
    }

    private var chart: some View {
        Chart(session.speedHistory) { sample in
            AreaMark(
                x: .value("t", sample.elapsed),
                y: .value(session.t(.unitAddrPerSec), sample.speed)
            )
            .foregroundStyle(
                LinearGradient(colors: [accent.opacity(0.4), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom)
            )
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("t", sample.elapsed),
                y: .value(session.t(.unitAddrPerSec), sample.speed)
            )
            .foregroundStyle(accent)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
        }
        .chartOverlay { proxy in
            if let last = session.speedHistory.last {
                GeometryReader { geo in
                    if let x = proxy.position(forX: last.elapsed), let y = proxy.position(forY: last.speed) {
                        let frame = geo[proxy.plotFrame!]
                        ZStack {
                            Circle().fill(accent.opacity(0.25)).frame(width: 16, height: 16)
                            Circle().fill(accent).frame(width: 6, height: 6)
                        }
                        .position(x: frame.minX + x, y: frame.minY + y)
                        .shadow(color: accent.opacity(0.7), radius: 6)
                    }
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Format.compact(v, session.language))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(height: 120)
        // Полностью гасим implicit-анимацию перерисовки графика: при
        // ежесекундных апдейтах она не успевает завершиться и создаёт
        // визуальные артефакты (сжатие/дрожание). Появление самой карточки
        // (emptyState -> chart) анимируется отдельно через .transition выше.
        .transaction { $0.animation = nil }
    }
}
