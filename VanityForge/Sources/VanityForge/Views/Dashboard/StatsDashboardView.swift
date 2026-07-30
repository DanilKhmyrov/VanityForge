import SwiftUI

struct StatsDashboardView: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusHeader

            HStack(spacing: 12) {
                StatTile(title: session.t(.statSpeed), value: speedText, unit: session.t(.unitAddrPerSec), icon: "bolt.fill", accent: accentColor)
                StatTile(title: session.t(.statChecked), value: totalText, unit: session.t(.unitAddresses), icon: "magnifyingglass", accent: accentColor)
                StatTile(title: session.t(.statTime), value: Format.elapsed(session.stats?.elapsedSeconds ?? 0), unit: nil, icon: "clock.fill", accent: accentColor)
                StatTile(title: session.t(.statWorkers), value: "\(session.stats?.workersTotal ?? session.started?.workersTotal ?? 0)", unit: session.t(.unitProcesses), icon: "cpu.fill", accent: accentColor)
            }

            HStack(alignment: .top, spacing: 12) {
                SpeedChartView()
                SystemMetricsView()
            }
        }
    }

    private var speedText: String {
        Format.compact(session.displaySpeed, session.language)
    }

    private var totalText: String {
        Format.compact(Double(session.stats?.totalChecked ?? 0), session.language)
    }

    private var accentColor: Color {
        session.orderedNetworks.first.map(NetworkVisual.accent(for:)) ?? .accentColor
    }

    @ViewBuilder
    private var statusHeader: some View {
        HStack(spacing: 10) {
            PulseDot(active: session.phase == .running, color: accentColor)

            Text(statusLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            if let gpu = session.started?.gpu, gpu.available {
                Label("\(session.t(.accelerated))\(gpu.toolLabel ?? "?")", systemImage: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.18)))
                    .foregroundStyle(.green)
            }

            if session.started?.fake == true {
                Label(session.t(.demoBadge), systemImage: "wand.and.stars")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.purple.opacity(0.2)))
                    .foregroundStyle(.purple)
            }

            if let best = session.rarestGap {
                Label("1 : \(Format.compact(best, session.language))", systemImage: "trophy.fill")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow.opacity(0.16)))
                    .foregroundStyle(Color.yellow)
                    .help(session.t(.rarestFindHelp))
            }

            Spacer()

            if let rarity = session.phase == .running ? session.liveRarity : session.lastStopped?.rarity1In {
                Text("\(session.t(.avgRarity))\(Format.compact(rarity, session.language))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: rarity)
            }
        }
    }

    private var statusLabel: String {
        switch session.phase {
        case .idle:
            return session.lastStopped != nil ? session.t(.statusStopped) : session.t(.statusReady)
        case .running:
            let net = session.started?.networksFull.values.joined(separator: ", ") ?? ""
            let preset = session.started?.presetDesc ?? ""
            return net.isEmpty ? session.t(.statusSearching) : "\(net) · \(preset)"
        case .stopping:
            return session.t(.stopping)
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let unit: String?
    let icon: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.5)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: value)
                    .foregroundStyle(.primary)
                if let unit {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .elevatedGlass(accent: accent, cornerRadius: 14, intensity: 0.8)
    }
}

private struct PulseDot: View {
    let active: Bool
    let color: Color
    @State private var animate = false

    var body: some View {
        ZStack {
            if active {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(animate ? 1.8 : 1)
                    .opacity(animate ? 0 : 1)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: animate)
            }
            Circle()
                .fill(active ? color : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
        }
        .frame(width: 14, height: 14)
        .onAppear { animate = active }
        .onChange(of: active) { _, newValue in animate = newValue }
    }
}
