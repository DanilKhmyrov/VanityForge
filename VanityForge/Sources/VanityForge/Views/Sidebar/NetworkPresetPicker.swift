import SwiftUI

struct NetworkPresetPicker: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(AppCatalog.self) private var catalog

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            section(session.t(.sectionNetworks)) {
                VStack(spacing: 8) {
                    ForEach(catalog.networkOrder, id: \.self) { key in
                        NetworkChip(
                            key: key,
                            name: catalog.networkNames[key] ?? key,
                            isSelected: session.selectedNetworks.contains(key),
                            disabled: session.isRunning
                        ) {
                            session.toggleNetwork(key)
                        }
                    }
                }
            }

            section(session.t(.sectionCondition)) {
                ConditionDropdown()
            }

            workerControl

            demoToggle

            Spacer(minLength: 0)

            LanguageSwitcher()

            StartStopButton()
        }
        .padding(20)
        .frame(width: 306)
        .background(sidebarBackground)
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [Color.white.opacity(0.09), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 1)
        }
    }

    private var sidebarBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [Color.white.opacity(0.05), .clear, Color.black.opacity(0.08)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .shadow(color: .black.opacity(0.4), radius: 24, x: 8, y: 0)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.55, green: 0.32, blue: 0.98), Color(red: 0.16, green: 0.78, blue: 0.72)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: Color(red: 0.55, green: 0.32, blue: 0.98).opacity(0.5), radius: 10, y: 4)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("VanityForge")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(session.t(.appSubtitle))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var workerControl: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.t(.workersTitle)).font(.system(size: 12, weight: .medium))
                Text(session.t(.workersSubtitle)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    session.workerCount = max(1, session.workerCount - 1)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning || session.workerCount <= 1)

                Text("\(session.workerCount)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(minWidth: 20)

                Button {
                    session.workerCount = min(session.maxWorkerCount, session.workerCount + 1)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning || session.workerCount >= session.maxWorkerCount)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var demoToggle: some View {
        Toggle(isOn: Binding(
            get: { session.fakeMode },
            set: { session.fakeMode = $0 }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.t(.demoModeTitle)).font(.system(size: 12, weight: .medium))
                Text(session.t(.demoModeSubtitle)).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(session.isRunning)
    }

    @ViewBuilder
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

private struct NetworkChip: View {
    let key: String
    let name: String
    let isSelected: Bool
    let disabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                NetworkIcon(key: key, size: 22)
                    .shadow(color: NetworkVisual.accent(for: key).opacity(isSelected ? 0.6 : 0), radius: 6)
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(NetworkVisual.accent(for: key))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    elevatedRow(accent: NetworkVisual.accent(for: key))
                } else {
                    plainRow
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
        .scaleEffect(hovering && !disabled ? 1.02 : 1)
        .rotation3DEffect(.degrees(hovering && !disabled ? -1.5 : 0), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
    }

    private func elevatedRow(accent: Color) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(accent.opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(accent.opacity(0.55), lineWidth: 1)
            )
            .shadow(color: accent.opacity(0.35), radius: 8, y: 3)
    }

    private var plainRow: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

/// Выпадающее меню условий поиска: свёрнуто показывает только выбранное
/// условие (список пресетов + описания редкости/времени иначе съедал бы
/// слишком много вертикального места в сайдбаре), разворачивается по клику.
private struct ConditionDropdown: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(AppCatalog.self) private var catalog
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(selectedLabel)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(session.isRunning)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    SpeedSourceControl()

                    Divider().overlay(Color.white.opacity(0.08))

                    VStack(spacing: 3) {
                        ForEach(session.availablePresets) { option in
                            ConditionRow(
                                description: option.description,
                                rarity: option.rarity1In,
                                isSelected: session.selectedPreset == option.key
                            ) {
                                session.selectedPreset = option.key
                                withAnimation(.easeOut(duration: 0.16)) { expanded = false }
                            }
                        }
                        ConditionRow(
                            description: session.t(.customPatternPlaceholderShort),
                            rarity: nil,
                            isSelected: session.isCustomPreset
                        ) {
                            session.selectedPreset = SessionViewModel.customPresetKey
                            withAnimation(.easeOut(duration: 0.16)) { expanded = false }
                        }
                    }
                }
                .padding(10)
                .elevatedGlass(cornerRadius: 12, intensity: 0.6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if session.isCustomPreset {
                CustomPatternInput()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if session.selectedPreset == "word" {
                WordListInput()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: session.isCustomPreset)
        .animation(.easeOut(duration: 0.18), value: session.selectedPreset == "word")
    }

    private var selectedLabel: String {
        if session.isCustomPreset {
            let text = session.customPatternText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? session.t(.customPatternPlaceholderShort) : "\(session.t(.customPatternSelected)): \"\(text)\""
        }
        return session.availablePresets.first(where: { $0.key == session.selectedPreset })?.description ?? session.t(.selectCondition)
    }
}

private struct ConditionRow: View {
    let description: String
    let rarity: UInt64?
    let isSelected: Bool
    let action: () -> Void

    @Environment(SessionViewModel.self) private var session
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.3))
                Text(description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                if let rarity {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("1 : \(Format.compact(rarity, session.language))")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        if let eta = session.etaSeconds(forRarity: rarity) {
                            Text("\(session.t(.rarityApprox))\(Format.duration(seconds: eta, session.language))")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary.opacity(0.8))
                        }
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.08) : (isSelected ? Color.white.opacity(0.05) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

private struct SpeedSourceControl: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Text(session.t(.speedEstimateTitle))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    Button {
                        session.speedEstimateAuto = true
                    } label: {
                        Text(session.t(.speedAuto))
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(session.speedEstimateAuto ? Color.white.opacity(0.14) : Color.clear))
                            .foregroundStyle(session.speedEstimateAuto ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        session.speedEstimateAuto = false
                    } label: {
                        Text(session.t(.speedManual))
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(!session.speedEstimateAuto ? Color.white.opacity(0.14) : Color.clear))
                            .foregroundStyle(!session.speedEstimateAuto ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(2)
                .background(Capsule().fill(Color.white.opacity(0.03)))

                if session.speedEstimateAuto {
                    Text(session.lastMeasuredSpeed.map { "\(Format.compact($0, session.language)) \(session.t(.unitAddrPerSec))" } ?? session.t(.noData))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    TextField(session.t(.unitAddrPerSec), text: Binding(
                        get: { session.manualSpeedText },
                        set: { session.manualSpeedText = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .frame(width: 80)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
                }
            }
        }
    }
}

private struct CustomPatternInput: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(AppCatalog.self) private var catalog

    private var rarity: UInt64? {
        catalog.customPatternRarity(
            pattern: session.customPatternText.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: session.customPatternMode,
            networks: session.selectedNetworks,
            caseSensitive: session.customPatternCaseSensitive
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(CustomPatternMode.allCases) { mode in
                        Button {
                            session.customPatternMode = mode
                        } label: {
                            Text(mode.label(session.language))
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .padding(.horizontal, 7).padding(.vertical, 5)
                                .frame(maxWidth: .infinity)
                                .background(
                                    Capsule().fill(session.customPatternMode == mode ? Color.white.opacity(0.12) : Color.clear)
                                )
                                .foregroundStyle(session.customPatternMode == mode ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .disabled(session.isRunning)

                AlphabetHintButton(networks: session.selectedNetworks)
            }

            TextField(placeholder, text: Binding(
                get: { session.customPatternText },
                set: { session.customPatternText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
            .disabled(session.isRunning)

            Toggle(isOn: Binding(
                get: { session.customPatternCaseSensitive },
                set: { session.customPatternCaseSensitive = $0 }
            )) {
                Text(session.t(.caseSensitiveToggle))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(session.isRunning)

            if let rarity {
                let dangerous = Format.rarityIsDangerous(rarity)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: dangerous ? "exclamationmark.triangle.fill" : "sparkles")
                            .font(.system(size: 9.5))
                        Text(dangerous
                             ? "\(session.t(.dangerousPatternPrefix))1 : \(Format.compact(rarity, session.language))"
                             : "\(session.t(.rarityApprox))1 : \(Format.compact(rarity, session.language))")
                            .font(.system(size: 10.5))
                    }
                    if let eta = session.etaSeconds(forRarity: rarity) {
                        Text("\(session.t(.etaLabel))\(Format.duration(seconds: eta, session.language))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(dangerous ? Color.orange : Color.secondary)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.15), value: rarity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    private var placeholder: String {
        switch session.customPatternMode {
        case .prefix: return session.t(.placeholderPrefix)
        case .suffix: return session.t(.placeholderSuffix)
        case .contains: return session.t(.placeholderContains)
        }
    }
}

private struct WordListInput: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(AppCatalog.self) private var catalog
    @State private var newWordText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            wordSection(title: session.t(.wordListDefaults), words: catalog.defaultWords, removable: false)

            if !session.customWords.isEmpty {
                wordSection(title: session.t(.wordListCustom), words: session.customWords, removable: true)
            }

            HStack(spacing: 6) {
                TextField(session.t(.wordListAddPlaceholder), text: $newWordText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                    .onSubmit(addWord)
                    .disabled(session.isRunning)
                Button(action: addWord) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(session.isRunning || newWordText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if session.selectedWords.isEmpty {
                Text(session.t(.wordListNoneSelected))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func wordSection(title: String, words: [String], removable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.4)
            FlowLayout(spacing: 6) {
                ForEach(words, id: \.self) { word in
                    WordChip(
                        word: word,
                        isSelected: session.selectedWords.contains(word),
                        removable: removable,
                        disabled: session.isRunning
                    ) {
                        session.toggleWord(word)
                    } onRemove: {
                        session.removeCustomWord(word)
                    }
                }
            }
        }
    }

    private func addWord() {
        session.addCustomWord(newWordText)
        newWordText = ""
    }
}

private struct WordChip: View {
    let word: String
    let isSelected: Bool
    let removable: Bool
    let disabled: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(word)
                .font(.system(size: 10.5, design: .monospaced))
            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .opacity(0.55)
                .disabled(disabled)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.05)))
        .overlay(Capsule().strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .opacity(disabled ? 0.5 : 1)
        .contentShape(Capsule())
        .onTapGesture { if !disabled { onToggle() } }
    }
}

private struct AlphabetHintButton: View {
    let networks: Set<String>
    @Environment(SessionViewModel.self) private var session
    @Environment(AppCatalog.self) private var catalog
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(session.t(.alphabetHintHelp))
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.t(.allowedChars))
                    .font(.system(size: 12, weight: .semibold))

                let relevant = catalog.networkOrder.filter { networks.contains($0) }
                ForEach(relevant.isEmpty ? catalog.networkOrder : relevant, id: \.self) { net in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            NetworkIcon(key: net, size: 14)
                            Text(catalog.networkNames[net] ?? net)
                                .font(.system(size: 12, weight: .medium))
                        }
                        if let info = NetworkAlphabet.info[net] {
                            Text(info.chars)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let note = info.note(session.language) {
                                Text(note)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 250, alignment: .leading)
        }
    }
}

private struct LanguageSwitcher: View {
    @Environment(SessionViewModel.self) private var session

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppLanguage.allCases) { lang in
                Button {
                    session.language = lang
                } label: {
                    Text(lang.rawValue.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(session.language == lang ? Color.white.opacity(0.14) : Color.clear))
                        .foregroundStyle(session.language == lang ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.03)))
    }
}

private struct StartStopButton: View {
    @Environment(SessionViewModel.self) private var session
    @State private var pulse = false

    var body: some View {
        Button {
            if session.isRunning { session.stop() } else { session.start() }
        } label: {
            HStack(spacing: 8) {
                if session.phase == .stopping {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: session.isRunning ? "stop.fill" : "bolt.fill")
                }
                Text(label)
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(.white)
            .background(
                Capsule().fill(
                    session.isRunning
                        ? LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
                        : accentGradient
                )
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(pulse && session.phase == .running ? 0.5 : 0), lineWidth: 2)
                    .scaleEffect(pulse && session.phase == .running ? 1.06 : 1)
            )
            .shadow(color: buttonShadowColor.opacity(0.5), radius: 16, y: 6)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled((!session.canStart && !session.isRunning) || session.phase == .stopping)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var label: String {
        switch session.phase {
        case .idle: return session.t(.startSearch)
        case .running: return session.t(.stopSearch)
        case .stopping: return session.t(.stopping)
        }
    }

    private var buttonShadowColor: Color {
        session.isRunning ? .red : (session.orderedNetworks.first.map(NetworkVisual.accent(for:)) ?? .accentColor)
    }

    private var accentGradient: LinearGradient {
        let keys = session.orderedNetworks
        if let first = keys.first {
            return NetworkVisual.gradient(for: first)
        }
        return LinearGradient(colors: [.gray, .gray.opacity(0.6)], startPoint: .leading, endPoint: .trailing)
    }
}
