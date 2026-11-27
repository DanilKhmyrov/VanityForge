import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Вкладка «Оценка»: вставляешь любой адрес — видишь, чем он красив, насколько
/// это редкость и сколько такой искать на этом Mac. Карточку можно скопировать
/// или сохранить картинкой. Всё считается локально (RarityAnalyzer).
struct RarityCheckerView: View {
    @Environment(SessionViewModel.self) private var session
    @Environment(AppCatalog.self) private var catalog
    @State private var input = ""
    @State private var copied = false

    private var words: [String] {
        catalog.defaultWords + catalog.bycatchWords.map(\.hex) + catalog.bycatchWords.map(\.word)
    }

    private var report: RarityReport? {
        RarityAnalyzer.analyze(input, words: words, lang: session.language)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.t(.rarityTitle)).font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(session.t(.raritySubtitle)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                inputField
                recentFinds
                content
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.never)
    }

    private var inputField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField(session.t(.rarityPlaceholder), text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
            if !input.isEmpty {
                Button { input = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
            Button {
                if let text = NSPasteboard.general.string(forType: .string) { input = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.plain)
            .help("Paste")
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .elevatedGlass(accent: .accentColor, cornerRadius: 12, intensity: 0.8)
    }

    @ViewBuilder
    private var recentFinds: some View {
        let recent = Array((session.foundItems + session.bycatchItems).prefix(8))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.t(.rarityRecentFinds).uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                FlowLayout(spacing: 6) {
                    ForEach(recent) { item in
                        Button { input = item.address } label: {
                            HStack(spacing: 5) {
                                if item.network == "eth" { BlockieView(address: item.address, size: 14) }
                                Text(Format.shortAddress(item.address, head: 8, tail: 6))
                                    .font(.system(size: 10.5, design: .monospaced))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            EmptyView()
        } else if let report {
            RarityShareCard(report: report, lang: session.language, speed: speed(for: report.network))
                .frame(maxWidth: 640)
            HStack(spacing: 8) {
                ShareButton(title: copied ? session.t(.copiedToast) : session.t(.rarityCopyCard), icon: copied ? "checkmark" : "doc.on.doc") {
                    copyImage(report)
                }
                ShareButton(title: session.t(.raritySaveCard), icon: "square.and.arrow.down") { saveImage(report) }
            }
            featureList(report)
        } else {
            Label(session.t(.rarityUnknown), systemImage: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        }
    }

    private func featureList(_ report: RarityReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.t(.rarityFeaturesTitle).uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
            if report.features.isEmpty {
                Text(session.t(.rarityNothing)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(report.features) { feature in
                HStack {
                    Text(feature.title).font(.system(size: 12))
                    Spacer()
                    Text("1 : \(Format.compact(1 / feature.probability, session.language))")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.04)))
            }
        }
        .frame(maxWidth: 640)
    }

    /// Скорость поиска такой красоты на этом Mac: EVM и TRON — видеокарта, остальное — процессор.
    private func speed(for network: String) -> Double {
        switch network {
        case "eth", "trx": return session.lastMeasuredGPUSpeed ?? 90_000_000
        case "sol": return 70_000
        default: return 120
        }
    }

    private func renderImage(_ report: RarityReport) -> NSImage? {
        let renderer = ImageRenderer(content:
            RarityShareCard(report: report, lang: session.language, speed: speed(for: report.network))
                .frame(width: 640)
                .padding(24)
                .background(Color(red: 0.06, green: 0.06, blue: 0.085))
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        return renderer.nsImage
    }

    private func copyImage(_ report: RarityReport) {
        guard let image = renderImage(report) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func saveImage(_ report: RarityReport) {
        guard let image = renderImage(report), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "vanity-\(report.address.prefix(10)).png"
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}

/// Карточка оценки — та же, что уходит в картинку, поэтому без @Environment.
struct RarityShareCard: View {
    let report: RarityReport
    let lang: AppLanguage
    let speed: Double

    private var tierColor: Color {
        switch report.tier {
        case .ordinary: return .gray
        case .nice: return Color(red: 0.36, green: 0.86, blue: 0.62)
        case .rare: return Color(red: 0.40, green: 0.62, blue: 0.98)
        case .veryRare: return Color(red: 0.62, green: 0.42, blue: 0.98)
        case .exceptional: return Color(red: 0.93, green: 0.36, blue: 0.72)
        case .legendary: return Color(red: 0.98, green: 0.74, blue: 0.22)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                if report.network == "eth" {
                    BlockieView(address: report.address, size: 72, cornerRadius: 14)
                } else {
                    NetworkIcon(key: report.network, size: 56)
                        .frame(width: 72, height: 72)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.tier.label.s(lang).uppercased())
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(tierColor)
                    HighlightedAddress(address: report.address, highlights: report.highlights, accent: tierColor, size: 16)
                    if let best = report.best {
                        Text(best.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    } else {
                        Text(L.rarityNothing.s(lang)).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
            }
            if report.best != nil {
                HStack(spacing: 10) {
                    metric(L.rarityOneIn.s(lang).replacingOccurrences(of: "{n}", with: Format.compact(report.attempts, lang)),
                           L.rarityBetterThan.s(lang).replacingOccurrences(of: "{p}", with: percent))
                    metric(String(format: "%.1f", report.bits), L.rarityBits.s(lang))
                    metric(Format.duration(seconds: report.attempts / speed, lang), L.rarityTimeOnMac.s(lang))
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                Text("VanityForge · " + L.rarityCardFooter.s(lang)).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.35))
        }
        .padding(20)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(red: 0.09, green: 0.09, blue: 0.12))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(RadialGradient(colors: [tierColor.opacity(0.28), .clear], center: .topLeading, startRadius: 10, endRadius: 420))
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tierColor.opacity(0.45), lineWidth: 1)
            }
        )
    }

    /// «99,9999998%» — столько девяток, сколько нужно, чтобы не округлить до 100.
    private var percent: String {
        let p = report.probability
        let digits = min(14, max(1, Int(ceil(-log10(p))) + 1))
        let value = (1 - p) * 100
        var text = String(format: "%.\(digits)f", value)
        while text.hasSuffix("0") && text.contains(".") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return (lang == .ru ? text.replacingOccurrences(of: ".", with: ",") : text) + "%"
    }

    private func metric(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

private struct ShareButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0.06)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
