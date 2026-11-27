import SwiftUI

/// Режим «Аватарка»: рисунок blockies 8×8 (левая половина, правая — зеркало),
/// цвета и допуск. Поиск — на видеокарте, см. AvatarTarget.spec.
struct AvatarForm: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AvatarStylePicker()
            if session.avatarStyle == .jazzicon {
                JazziconGallery()
                rarityCard
            } else {
                blockiesForm
            }
        }
        .disabled(session.isRunning)
    }

    private var blockiesForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            section(session.t(.sectionAvatarDrawing)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        AvatarGridEditor()
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(AvatarDrawing.allCases) { drawing in
                                Button {
                                    var target = session.avatarTarget
                                    target.cells = AvatarTarget(rows: drawing.rows).cells
                                    session.avatarTarget = target
                                } label: {
                                    Text(session.t(drawing.label))
                                        .font(.system(size: 11, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Capsule().fill(Color.white.opacity(0.05)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    CellLegend()
                    Text(session.t(.avatarHint))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    missesStepper
                    fitTimeRow
                }
            }

            section(session.t(.sectionAvatarColors)) {
                VStack(alignment: .leading, spacing: 10) {
                    SwatchRow(title: session.t(.avatarColorMain), value: binding(\.color))
                    SwatchRow(title: session.t(.avatarColorBackground), value: binding(\.background))
                    SwatchRow(title: session.t(.avatarColorSpot), value: binding(\.spot))
                }
            }

            rarityCard
        }
    }

    private func binding(_ key: WritableKeyPath<AvatarTarget, AvatarSwatch>) -> Binding<AvatarSwatch> {
        Binding(get: { session.avatarTarget[keyPath: key] }, set: { session.avatarTarget[keyPath: key] = $0 })
    }

    private var missesStepper: some View {
        HStack {
            Text(session.t(.avatarMisses)).font(.system(size: 11.5))
            Spacer()
            HStack(spacing: 8) {
                Button { session.avatarTarget.misses = max(0, session.avatarTarget.misses - 1) } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(session.avatarTarget.misses == 0)
                Text("\(session.avatarTarget.misses)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(minWidth: 16)
                Button { session.avatarTarget.misses = min(AvatarTarget.maxMisses, session.avatarTarget.misses + 1) } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(session.avatarTarget.misses >= AvatarTarget.maxMisses)
            }
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
        }
    }

    /// «Хочу найти за минуту» — подбирает наименьший допуск под это время.
    private var fitTimeRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.t(.avatarFitTime)).font(.system(size: 10.5)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(SessionViewModel.avatarFitTimes, id: \.self) { seconds in
                    Button { session.fitAvatarMisses(seconds: seconds) } label: {
                        Text("≤ " + Format.duration(seconds: seconds, session.language))
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                            .background(Capsule().fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var rarityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let rarity = session.targetRarity {
                HStack {
                    Text(session.t(.rarityApprox))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("1 : \(Format.compact(rarity, session.language))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Format.rarityIsDangerous(rarity) ? .orange : .primary)
                }
                if let eta = session.etaSeconds(forRarity: rarity) {
                    HStack {
                        Text(session.t(.etaLabel)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Text(Format.duration(seconds: eta, session.language))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                }
                if session.avatarStyle == .blockies, session.avatarTarget.cells.contains(.spot) {
                    Text(session.t(.avatarSpotsNote))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(session.t(session.avatarStyle == .jazzicon ? .jazziconPick : .avatarEmpty))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if !session.useGPU {
                Label(session.t(.avatarGPUOnly), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        )
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            content()
        }
    }
}

/// Цвета клеток в редакторе: условные (не цвета найденной аватарки).
enum AvatarCellStyle {
    static func fill(_ cell: AvatarCell, target: AvatarTarget) -> Color {
        switch cell {
        case .any: return Color.white.opacity(0.04)
        case .background: return target.background == .any ? Color(white: 0.30) : target.background.preview.opacity(0.75)
        case .color: return target.color == .any ? Color(red: 0.93, green: 0.36, blue: 0.72) : target.color.preview
        case .spot: return target.spot == .any ? Color(red: 0.98, green: 0.80, blue: 0.25) : target.spot.preview
        }
    }
}

private struct AvatarGridEditor: View {
    @Environment(SessionViewModel.self) private var session
    private let cell: CGFloat = 17

    var body: some View {
        let target = session.avatarTarget
        VStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<8, id: \.self) { column in
                        let value = target.cell(row: row, column: column)
                        Button {
                            session.avatarTarget.cycle(row: row, column: column)
                        } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(AvatarCellStyle.fill(value, target: target))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(Color.white.opacity(value == .any ? 0.12 : 0.2),
                                                      style: StrokeStyle(lineWidth: 1, dash: value == .any ? [2, 2] : []))
                                )
                                .frame(width: cell, height: cell)
                                // Правая половина — зеркало: её клетки чуть тусклее.
                                .opacity(column < 4 ? 1 : 0.8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
    }
}

private struct CellLegend: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        HStack(spacing: 10) {
            item(.any, session.t(.swatchAny))
            item(.background, session.t(.avatarColorBackground))
            item(.color, session.t(.avatarColorMain))
            item(.spot, session.t(.avatarColorSpot))
        }
    }

    private func item(_ cell: AvatarCell, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(AvatarCellStyle.fill(cell, target: session.avatarTarget))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                .frame(width: 10, height: 10)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct SwatchRow: View {
    @Environment(SessionViewModel.self) private var session
    let title: String
    @Binding var value: AvatarSwatch

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text(session.t(value.label)).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(AvatarSwatch.allCases) { swatch in
                    Button { value = swatch } label: {
                        ZStack {
                            Circle().fill(swatch == .any ? Color.white.opacity(0.05) : swatch.preview)
                            if swatch == .any {
                                Image(systemName: "asterisk").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.white.opacity(value == swatch ? 0.9 : 0.15), lineWidth: value == swatch ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(session.t(swatch.label))
                }
            }
        }
    }
}

/// Etherscan (blockies) или MetaMask (jazzicon).
private struct AvatarStylePicker: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AvatarStyle.allCases) { style in
                Button { session.avatarStyle = style } label: {
                    VStack(spacing: 4) {
                        Group {
                            if style == .blockies {
                                BlockieView(address: "0x5ca1ab1e00000000000000000000000000c0ffee", size: 26)
                            } else {
                                JazziconView(seed: session.jazziconSeed ?? 0x5ca1ab1e, size: 26)
                            }
                        }
                        Text(session.t(style == .blockies ? .avatarStyleBlockies : .avatarStyleJazzicon))
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(style == .blockies ? "blockies" : "jazzicon")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(session.avatarStyle == style ? 0.10 : 0.03))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(session.avatarStyle == style ? 0.35 : 0.07), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Галерея иконок MetaMask: каждая — это первые 8 символов адреса. Выбрали —
/// видеокарта ищет адрес с таким началом (16^8 попыток).
private struct JazziconGallery: View {
    @Environment(SessionViewModel.self) private var session
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(session.t(.sectionJazziconGallery).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.2)) { session.shuffleJazziconGallery() } } label: {
                    Label(session.t(.jazziconMore), systemImage: "shuffle")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if let seed = session.jazziconSeed {
                HStack(spacing: 12) {
                    JazziconView(seed: seed, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("0x" + String(format: "%08x", seed) + "…")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        Text(session.t(.jazziconSelectedHint))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(session.jazziconGallery, id: \.self) { seed in
                    Button { session.jazziconSeed = seed } label: {
                        JazziconView(seed: seed, size: 38)
                            .overlay(Circle().strokeBorder(Color.white.opacity(session.jazziconSeed == seed ? 0.95 : 0), lineWidth: 2.5))
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(session.t(.jazziconHint))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Переключатель побочного улова — в параметрах кошельков и аватарки.
struct BycatchToggle: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { session.bycatchEnabled }, set: { session.bycatchEnabled = $0 })) {
                HStack(spacing: 6) {
                    Label(session.t(.bycatchToggle), systemImage: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                    if !session.bycatchAvailable {
                        Text(session.t(.bycatchCPUNote))
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(session.isRunning || !session.bycatchAvailable)
            Text(session.t(.bycatchToggleHint))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
