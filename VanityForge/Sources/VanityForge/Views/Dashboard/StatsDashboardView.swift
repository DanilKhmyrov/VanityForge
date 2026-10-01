import SwiftUI

struct StatsDashboardView: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusHeader

            HStack(spacing: 12) {
                StatTile(title: session.t(.statSpeed), value: speedText, unit: session.t(session.searchMode == .contracts ? .unitAttemptsPerSec : .unitAddrPerSec), icon: "bolt.fill", accent: accentColor)
                StatTile(title: session.t(.statChecked), value: totalText, unit: session.t(.unitAddresses), icon: "magnifyingglass", accent: accentColor,
                         footnote: session.foundItems.isEmpty ? nil : "\(session.t(.feedTitle)): \(session.foundItems.count)")
                StatTile(title: session.t(.statTime), value: Format.elapsed(session.stats?.elapsedSeconds ?? 0), unit: nil, icon: "clock.fill", accent: accentColor)
                ChanceTile(accent: accentColor)
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
        session.accentKey.map(NetworkVisual.accent(for:)) ?? .accentColor
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

            if let workers = session.stats?.workersTotal ?? session.started?.workersTotal, session.isRunning, workers > 1 {
                chip("\(workers) \(session.t(.unitProcesses))", icon: "cpu", color: .white)
            }

            if session.isRunning, session.searchMode == .wallets, session.useGPU,
               session.started?.fake == false, session.started?.gpu.tool != "metal" {
                chip(session.t(.cpuOnlyChip), icon: "cpu", color: .orange)
                    .help(session.t(.cpuOnlyHelp))
            }

            if session.keepsAwake {
                chip(session.t(.keepAwakeChip), icon: "cup.and.saucer.fill", color: .orange)
                    .help(session.t(.keepAwakeHelp))
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

    private func chip(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(color == .white ? 0.07 : 0.16)))
            .foregroundStyle(color == .white ? Color.secondary : color)
            .lineLimit(1)
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
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TileHeader(title: title, icon: icon, accent: accent)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 25, weight: .bold, design: .rounded).monospacedDigit())
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

            Text(footnote ?? " ")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .elevatedGlass(accent: accent, cornerRadius: 14, intensity: 0.8)
    }
}

private struct TileHeader: View {
    let title: String
    let icon: String
    let accent: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .shadow(color: accent.opacity(0.45), radius: 5, y: 2)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
                .lineLimit(1)
        }
    }
}

/// Вероятность уже найти хотя бы один адрес при текущей редкости условия.
/// Кольцо заполняется по 1 − e^(−проверено/N): 63% — ровно «в среднем пора».
private struct ChanceTile: View {
    let accent: Color
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        let chance = session.findChance
        VStack(alignment: .leading, spacing: 8) {
            TileHeader(title: session.t(.statChance), icon: "target", accent: accent)
            HStack(alignment: .center, spacing: 8) {
                Text(chance.map { percent($0) } ?? "—")
                    .font(.system(size: 25, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: chance ?? 0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: chance ?? 0)
                        .stroke(
                            AngularGradient(colors: [accent.opacity(0.6), accent, Color.yellow], center: .center),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .shadow(color: accent.opacity(0.6), radius: 3)
                        .animation(.easeOut(duration: 0.6), value: chance ?? 0)
                }
                .frame(width: 26, height: 26)
            }
            Text(footnote)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .elevatedGlass(accent: accent, cornerRadius: 14, intensity: 0.8)
        .help("1 − e^(−checked / N)")
    }

    private func percent(_ value: Double) -> String {
        let p = value * 100
        if p >= 99.95 { return ">99.9%" }
        return p < 10 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p)
    }

    private var footnote: String {
        guard let rarity = session.targetRarity else { return session.t(.chanceNoData) }
        if let seconds = session.secondsPerFind {
            return session.t(.chanceAvgPrefix) + Format.duration(seconds: seconds, session.language)
        }
        return "1 : \(Format.compact(rarity, session.language))"
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
