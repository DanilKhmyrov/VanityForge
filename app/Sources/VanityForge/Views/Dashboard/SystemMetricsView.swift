import SwiftUI

struct SystemMetricsView: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.t(.systemHeader))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)

            MetricRow(label: "CPU", value: monitor.cpuUsage, detail: percent(monitor.cpuUsage), color: .blue)
            MetricRow(label: session.t(.memory), value: monitor.memoryUsage, detail: memoryDetail, color: .purple)
            if let gpu = monitor.gpuUsage {
                MetricRow(label: "GPU", value: gpu, detail: percent(gpu), color: .green)
            } else {
                MetricRow(label: "GPU", value: 0, detail: session.t(.notAvailable), color: .gray, disabled: true)
            }
        }
        .padding(16)
        .frame(width: 190, alignment: .leading)
        .elevatedGlass(cornerRadius: 14, intensity: 0.6)
    }

    private func percent(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    private var memoryDetail: String {
        String(format: "%.1f/%.0f GB", monitor.memoryUsedGB, monitor.memoryTotalGB)
    }
}

private struct MetricRow: View {
    let label: String
    let value: Double
    let detail: String
    let color: Color
    var disabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
                    Capsule()
                        .fill(disabled ? AnyShapeStyle(Color.gray.opacity(0.3)) : AnyShapeStyle(color.gradient))
                        .frame(width: max(3, geo.size.width * value))
                        .shadow(color: disabled ? .clear : color.opacity(0.6), radius: 4, y: 1)
                        .animation(.easeOut(duration: 0.6), value: value)
                }
            }
            .frame(height: 6)
        }
        .opacity(disabled ? 0.55 : 1)
    }
}
