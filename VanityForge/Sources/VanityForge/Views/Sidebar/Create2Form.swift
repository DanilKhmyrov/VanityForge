import SwiftUI

/// Сайдбар режима «Контракты»: параметры заказчика (фабрика, хеш кода,
/// кошелёк) и условие на адрес. Заменяет выбор сетей и пресетов.
struct Create2Form: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section(session.t(.sectionKind)) { kindPicker }
            if session.contractKind == .create2 {
                section(session.t(.sectionFactory)) { factoryPicker }
            }
            section(session.t(.sectionContract)) { contractFields }
            section(session.t(.sectionTarget)) { targetPicker }
            gpuToggle
        }
        .disabled(session.isRunning)
        .onChange(of: session.create2InitCodeHash) { session.saveCreate2Settings() }
        .onChange(of: session.create2Caller) { session.saveCreate2Settings() }
        .onChange(of: session.create2CustomFactory) { session.saveCreate2Settings() }
        .onChange(of: session.create2Prefix) { session.saveCreate2Settings() }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(ContractKind.allCases) { kind in
                    Button {
                        session.contractKind = kind
                        session.saveCreate2Settings()
                    } label: {
                        Text(kind.label)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(Capsule().fill(session.contractKind == kind ? Color.white.opacity(0.13) : Color.white.opacity(0.03)))
                            .foregroundStyle(session.contractKind == kind ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(session.contractKind.hint(session.language))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if session.contractKind == .create3 {
                Text("CreateX \(ContractKind.createX)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private var factoryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(Create2Factory.allCases) { factory in
                    Button(factory.label(session.language)) {
                        session.create2Factory = factory
                        session.saveCreate2Settings()
                    }
                }
            } label: {
                HStack {
                    Text(session.create2Factory.label(session.language))
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            if session.create2Factory == .custom {
                HexField(placeholder: session.t(.create2FactoryPlaceholder),
                         text: Binding(get: { session.create2CustomFactory }, set: { session.create2CustomFactory = $0 }),
                         valid: session.create2CustomFactory.isEmpty || session.create2FactoryValid)
            } else if let address = session.create2Factory.address {
                Text(address)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !session.create2Factory.protectsCaller {
                Warning(text: session.t(.create2FactoryUnprotected))
            }
        }
    }

    private var contractFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.contractKind == .create2 {
                HexField(placeholder: session.t(.create2InitCodeHash),
                         text: Binding(get: { session.create2InitCodeHash }, set: { session.create2InitCodeHash = $0 }),
                         valid: session.create2InitCodeHash.isEmpty || session.create2InitCodeHashValid)
                    .help(session.t(.create2InitCodeHashHelp))
            }

            HexField(placeholder: session.t(.create2Caller),
                     text: Binding(get: { session.create2Caller }, set: { session.create2Caller = $0 }),
                     valid: session.create2CallerValid)
                .help(session.t(.create2CallerHelp))

            if session.create2CallerTrimmed.isEmpty {
                Warning(text: session.t(session.contractKind == .create3 ? .create3CallerMissing : .create2CallerMissing))
            }
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                    ForEach(Create2Goal.allCases) { goal in
                        Button {
                            session.create2Goal = goal
                            session.saveCreate2Settings()
                        } label: {
                            Text(goal.label(session.language))
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(Capsule().fill(session.create2Goal == goal ? Color.white.opacity(0.13) : Color.white.opacity(0.03)))
                                .foregroundStyle(session.create2Goal == goal ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
            }

            HStack(alignment: .top, spacing: 6) {
                Text(session.create2Goal.hint(session.language))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                ExplainButton()
            }

            switch session.create2Goal {
            case .leading, .zeros:
                minBytesStepper
            case .prefix:
                HexField(placeholder: session.t(.create2PrefixPlaceholder),
                         text: Binding(get: { session.create2Prefix }, set: { session.create2Prefix = $0 }),
                         valid: session.create2Prefix.isEmpty || session.create2PrefixValid)
            case .hook:
                HookFlagsPicker()
            }

            rarityLine
        }
    }

    private var gpuToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { session.create2UseGPU }, set: {
                session.create2UseGPU = $0
                session.saveCreate2Settings()
            })) {
                Label(session.t(.create2UseGPU), systemImage: "cpu")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text(session.t(.create2UseGPUHint))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var minBytesStepper: some View {
        HStack {
            Text(session.t(.create2MinBytes)).font(.system(size: 12, weight: .medium))
            Spacer()
            HStack(spacing: 8) {
                Button {
                    session.create2MinBytes = max(1, session.create2MinBytes - 1)
                    session.saveCreate2Settings()
                } label: { Image(systemName: "minus.circle.fill").font(.system(size: 15)) }
                .buttonStyle(.plain)
                .disabled(session.create2MinBytes <= 1)

                Text("\(session.create2MinBytes)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(minWidth: 20)

                Button {
                    session.create2MinBytes = min(Create2Math.addressBytes, session.create2MinBytes + 1)
                    session.saveCreate2Settings()
                } label: { Image(systemName: "plus.circle.fill").font(.system(size: 15)) }
                .buttonStyle(.plain)
                .disabled(session.create2MinBytes >= 12)
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var rarityLine: some View {
        if let rarity = session.create2Rarity {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.t(.rarityApprox))1 : \(Format.compact(rarity, session.language))")
                    .font(.system(size: 10.5))
                if let eta = session.etaSeconds(forRarity: rarity) {
                    Text("\(session.t(.etaLabel))\(Format.duration(seconds: eta, session.language))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            content()
        }
    }
}

private struct HexField: View {
    let placeholder: String
    @Binding var text: String
    let valid: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(valid ? Color.white.opacity(0.1) : Color.orange.opacity(0.7), lineWidth: 1)
            )
    }
}

private struct Warning: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5))
            Text(text).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange)
    }
}

private struct HookFlagsPicker: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 5) {
                ForEach(HookFlag.all) { flag in
                    let on = session.create2HookFlags & flag.mask != 0
                    Text(flag.name)
                        .font(.system(size: 9.5, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(on ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.05)))
                        .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .contentShape(Capsule())
                        .onTapGesture {
                            session.create2HookFlags ^= flag.mask
                            session.saveCreate2Settings()
                        }
                }
            }
            Text("\(session.t(.create2HookMask)): 0x\(String(format: "%04x", session.create2HookFlags))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ExplainButton: View {
    @Environment(SessionViewModel.self) private var session
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "questionmark.circle").font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            Text(session.t(.create2Explain))
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(width: 280, alignment: .leading)
        }
    }
}
