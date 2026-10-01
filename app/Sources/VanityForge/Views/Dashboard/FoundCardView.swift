import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct FoundCardView: View {
    let event: FoundEvent
    @Environment(SessionViewModel.self) private var session

    @State private var revealed = false
    @State private var addressCopied = false
    @State private var checksumCopied = false
    @State private var keyCopied = false
    @State private var saltCopied = false
    @State private var clientCopied = false
    @State private var allCopied = false
    @State private var showingQR = false
    /// Свежая находка на секунду-другую "вспыхивает" рамкой/свечением —
    /// приятная обратная связь в духе "поймали", затем гаснет до обычного вида.
    @State private var justArrived = true
    @State private var hovering = false

    private var accent: Color { NetworkVisual.accent(for: event.network) }
    private var balances: [String: Double]? { session.balancesBySeq[event.seq] }
    private var fileURL: URL { ResultsLocation.resolve(event.filepath) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(NetworkVisual.gradient(for: event.network))
                .frame(width: 4)
                .padding(.vertical, 2)
                .shadow(color: accent.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 10) {
                topRow
                if event.isContract {
                    contractRows
                } else {
                    addressRow
                    if let checksum = event.checksumAddress, checksum != event.address { checksumRow(checksum) }
                    if event.network == "eth" { balanceRow }
                    if event.isSplitKey { splitKeyRows } else { privateKeyRow }
                }
                actionBar
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .elevatedGlass(accent: accent, cornerRadius: 14, intensity: justArrived ? 1.6 : (hovering ? 1.15 : 1.0))
        .overlay {
            if justArrived {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent.opacity(0.9), lineWidth: 1.6)
                ParticleBurst(color: accent, seed: event.seq)
            }
        }
        .shadow(color: accent.opacity(justArrived ? 0.5 : 0), radius: justArrived ? 20 : 0)
        .scaleEffect(justArrived ? 1.015 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onAppear {
            withAnimation(.easeOut(duration: 1.3)) { justArrived = false }
        }
        .contextMenu { contextItems }
    }

    // MARK: - Шапка

    private var topRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                NetworkIcon(key: event.network, size: 14)
                Text(event.networkFull)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(accent.opacity(0.2)))
            .foregroundStyle(accent)
            .fixedSize()

            if !event.isContract {
                FlowLayout(spacing: 5) {
                    ForEach(event.matchedDesc, id: \.self) { desc in
                        badge(desc, color: .white)
                    }
                    ForEach(event.foundWords, id: \.self) { word in
                        Label(word, systemImage: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.yellow.opacity(0.16)))
                            .foregroundStyle(.yellow)
                    }
                }
            }

            Spacer(minLength: 6)
            Text(foundTime)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .help(event.foundAt.replacingOccurrences(of: "T", with: " "))
                .fixedSize()
        }
    }

    /// «02:35:06» для сегодняшних находок, полная дата — в подсказке.
    private var foundTime: String {
        let parts = event.foundAt.replacingOccurrences(of: "T", with: " ").split(separator: " ")
        return parts.count == 2 ? String(parts[1]) : event.foundAt
    }

    // MARK: - Адрес и ключ

    private var addressRow: some View {
        HStack(spacing: 8) {
            HighlightedAddress(address: event.address, highlights: highlightRanges, accent: accent, size: 15)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            CopyButton(copied: $addressCopied) { copy(event.address) }
        }
    }

    private func checksumRow(_ checksum: String) -> some View {
        HStack(spacing: 8) {
            Text("checksum")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(checksum)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            CopyButton(copied: $checksumCopied) { copy(checksum) }
        }
    }

    @ViewBuilder
    private var balanceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "banknote")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            if let balances {
                Text(balanceText(balances))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(balances.values.contains(where: { $0 > 0 }) ? Color.green : Color.white.opacity(0.35))
            } else if session.balanceLoading.contains(event.seq) {
                ProgressView().controlSize(.mini)
                Text(session.t(.calculatingBalance))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    session.checkBalance(for: event)
                } label: {
                    Text(session.t(.checkBalance))
                        .font(.system(size: 10.5, weight: .medium))
                        .underline()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(session.t(.checkBalanceHelp))
                if session.balanceFailed.contains(event.seq) {
                    Text(session.t(.balanceFailed))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
        }
        .transition(.opacity)
        .animation(.easeOut(duration: 0.25), value: balances != nil)
    }

    private func balanceText(_ balances: [String: Double]) -> String {
        balances
            .sorted { $0.value > $1.value }
            .map { String(format: "%.6f %@", $0.value, $0.key) }
            .joined(separator: "  ·  ")
    }

    private var privateKeyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: revealed ? "key.fill" : "key")
                .font(.system(size: 10))
                .foregroundStyle(revealed ? accent : Color.white.opacity(0.35))
            Text(event.privateKey)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .blur(radius: revealed ? 0 : 6)
                .overlay(alignment: .leading) {
                    if !revealed {
                        Text(session.t(.holdToRevealKey))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 40) {
                } onPressingChanged: { pressing in
                    withAnimation(.easeOut(duration: 0.15)) { revealed = pressing }
                }
            Spacer(minLength: 4)
            CopyButton(copied: $keyCopied) { copy(event.privateKey) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.18)))
    }

    // MARK: - Split-key

    @ViewBuilder
    private var splitKeyRows: some View {
        if let tweak = event.tweak {
            HStack(spacing: 8) {
                label(session.t(.splitKeyTweak))
                Text(tweak)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                CopyButton(copied: $saltCopied) { copy(tweak) }
            }
        }
        HStack(spacing: 8) {
            badge(session.t(.splitKeyBadge), color: .green)
            Spacer()
            clientButton(summary: splitKeySummary)
        }
    }

    private var splitKeySummary: String {
        [
            "Vanity address:  \(event.checksumAddress ?? event.address)",
            "Tweak (k):       \(event.tweak ?? "")",
            "Your public key: \(event.clientPubkey ?? "")",
            "",
            "Your private key for this address = (your private key + k) mod n.",
            "Only you know it. To compute it locally:",
            "python3 python/splitkey.py combine <your private key> \(event.tweak ?? "") \(event.network)",
        ].joined(separator: "\n")
    }

    // MARK: - Контракты

    @ViewBuilder
    private var contractRows: some View {
        let address = event.checksumAddress ?? event.address
        HStack(spacing: 8) {
            HighlightedAddress(address: address, highlights: highlightRanges, accent: accent, size: 15)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            CopyButton(copied: $addressCopied) { copy(address) }
        }

        HStack(spacing: 6) {
            if let leading = event.leadingZeroBytes {
                badge("\(session.t(.create2LeadingZeroBytes))\(leading)", color: .yellow)
            }
            if let zeros = event.zeroBytes {
                badge("\(session.t(.create2ZeroBytes))\(zeros)", color: .orange)
            }
            ForEach(event.matchedDesc, id: \.self) { desc in
                badge(desc, color: .white)
            }
            Spacer()
        }

        if let salt = event.salt {
            HStack(spacing: 8) {
                label(session.t(.create2Salt))
                Text(salt)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                CopyButton(copied: $saltCopied) { copy(salt) }
            }
        }

        HStack(spacing: 14) {
            if let factory = event.factory { smallField(session.t(.create2Factory), factory) }
            if let caller = event.caller { smallField(session.t(.create2Deployer), caller) }
            Spacer(minLength: 0)
        }
    }

    private var clientSummary: String {
        var lines = [
            "Contract address: \(event.checksumAddress ?? event.address)",
            "Salt:             \(event.salt ?? "")",
            "Factory:          \(event.factory ?? "")",
            "Deployer wallet:  \(event.caller ?? "")",
        ]
        if let hash = event.initCodeHash {
            lines.append("Init code hash:   \(hash)")
        }
        if event.network == ContractKind.create3.rawValue {
            lines.append("Deploy:           CreateX.deployCreate3(salt, initCode) from the deployer wallet — any contract code")
        }
        return lines.joined(separator: "\n")
    }

    private func clientButton(summary: String) -> some View {
        Button {
            copy(summary)
            clientCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { clientCopied = false }
        } label: {
            Label(session.t(.create2CopyForClient), systemImage: clientCopied ? "checkmark" : "paperplane.fill")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(accent.opacity(0.18)))
                .foregroundStyle(clientCopied ? Color.green : accent)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Действия

    private var actionBar: some View {
        HStack(spacing: 6) {
            ActionPill(title: session.t(.openFile), icon: "doc.text") { openFile() }
            ActionPill(title: session.t(.revealInFinder), icon: "folder") { revealInFinder() }
            if explorerURL != nil {
                ActionPill(title: session.t(.openExplorer), icon: "arrow.up.right.square") { openExplorer() }
            }
            ActionPill(title: session.t(.showQR), icon: "qrcode") { showingQR = true }
                .popover(isPresented: $showingQR, arrowEdge: .bottom) { qrPopover }
            Spacer(minLength: 4)
            if event.isContract {
                clientButton(summary: clientSummary)
            } else {
                ActionPill(title: allCopied ? session.t(.copiedToast) : session.t(.copyAll),
                           icon: allCopied ? "checkmark" : "doc.on.clipboard",
                           tint: allCopied ? .green : accent, prominent: true) {
                    copy(fullSummary)
                    allCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { allCopied = false }
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var contextItems: some View {
        Button(session.t(.openFile)) { openFile() }
        Button(session.t(.revealInFinder)) { revealInFinder() }
        if explorerURL != nil { Button(session.t(.openExplorer)) { openExplorer() } }
        Divider()
        Button(session.t(.copyAll)) { copy(event.isContract ? clientSummary : fullSummary) }
    }

    private var qrPopover: some View {
        let address = event.checksumAddress ?? event.address
        return VStack(spacing: 10) {
            if let image = QRCode.image(for: address) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            }
            Text(address)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .frame(width: 220)
            Text(session.t(.qrCaption))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 220)
        }
        .padding(16)
    }

    /// Для «Скопировать всё» у кошелька: всё, что нужно, чтобы им пользоваться.
    private var fullSummary: String {
        var lines = ["Network:     \(event.networkFull)", "Address:     \(event.checksumAddress ?? event.address)"]
        if event.isSplitKey {
            lines.append("Tweak (k):   \(event.tweak ?? "")")
        } else {
            lines.append("Private key: \(event.privateKey)")
        }
        if !event.matchedDesc.isEmpty { lines.append("Conditions:  \(event.matchedDesc.joined(separator: "; "))") }
        lines.append("File:        \(fileURL.path)")
        return lines.joined(separator: "\n")
    }

    private var explorerURL: URL? {
        let address = event.checksumAddress ?? event.address
        switch event.network {
        case "eth", ContractKind.create2.rawValue, ContractKind.create3.rawValue:
            return URL(string: "https://etherscan.io/address/\(address)")
        case "trx": return URL(string: "https://tronscan.org/#/address/\(address)")
        case "sol": return URL(string: "https://solscan.io/account/\(address)")
        case "ton", "tonsub": return URL(string: "https://tonviewer.com/\(address)")
        default: return nil
        }
    }

    private func openFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            session.lastError = session.t(.fileMissing) + fileURL.path
            return
        }
        NSWorkspace.shared.open(fileURL)
    }

    private func revealInFinder() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            session.lastError = session.t(.fileMissing) + fileURL.path
        }
    }

    private func openExplorer() {
        if let explorerURL { NSWorkspace.shared.open(explorerURL) }
    }

    // MARK: - Подсветка совпадения

    /// Какие символы адреса «сделали» его красивым: одинаковые в начале/конце,
    /// слова из списка, свой паттерн. Индексы — по строке адреса целиком.
    private var highlightRanges: [Range<Int>] {
        let address = event.isContract ? (event.checksumAddress ?? event.address) : event.address
        let chars = Array(address)
        let offset = address.hasPrefix("0x") || address.hasPrefix("EQ") || address.hasPrefix("UQ") ? 2 : 0
        let body = String(chars[offset...]).lowercased()
        let bodyChars = Array(body)
        var ranges: [Range<Int>] = []

        func add(_ start: Int, _ length: Int) {
            guard length > 0 else { return }
            ranges.append((offset + start)..<(offset + start + length))
        }

        if let first = bodyChars.first {
            let run = bodyChars.prefix(while: { $0 == first }).count
            if run >= 4 || (event.isContract && first == "0" && run >= 2) { add(0, run) }
        }
        if let last = bodyChars.last {
            let run = bodyChars.reversed().prefix(while: { $0 == last }).count
            if run >= 4 { add(bodyChars.count - run, run) }
        }

        var words = event.foundWords.map { $0.lowercased() }
        if event.matched.contains("deadprefixsuffix") { words.append("dead") }
        if event.matched.contains(SessionViewModel.customPresetKey) {
            let pattern = session.customPatternText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !pattern.isEmpty {
                switch session.customPatternMode {
                case .prefix: if body.hasPrefix(pattern) { add(0, pattern.count) }
                case .suffix: if body.hasSuffix(pattern) { add(bodyChars.count - pattern.count, pattern.count) }
                case .contains:
                    if let range = body.range(of: pattern) {
                        add(body.distance(from: body.startIndex, to: range.lowerBound), pattern.count)
                    }
                }
            }
        }
        if event.isContract, session.create2Goal == .prefix {
            let wanted = Create2Math.strip(session.create2Prefix).lowercased()
            if !wanted.isEmpty, body.hasPrefix(wanted) { add(0, wanted.count) }
        }
        for word in words where !word.isEmpty {
            if body.hasPrefix(word) { add(0, word.count) }
            if body.hasSuffix(word) { add(bodyChars.count - word.count, word.count) }
        }
        return ranges
    }

    // MARK: - Мелочи

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color == .white ? Color.secondary : color)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func smallField(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            label(title)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Адрес моноширинным шрифтом, где «красивая» часть выделена цветом сети.
/// Не обрезается многоточием — ради этих символов адрес и искали; если не
/// влезает, шрифт слегка уменьшается.
struct HighlightedAddress: View {
    let address: String
    let highlights: [Range<Int>]
    let accent: Color
    var size: CGFloat = 14

    var body: some View {
        Text(attributed)
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private var attributed: AttributedString {
        let chars = Array(address)
        var marked = [Bool](repeating: false, count: chars.count)
        for range in highlights {
            for i in range where i >= 0 && i < chars.count { marked[i] = true }
        }
        let prefixLength = address.hasPrefix("0x") ? 2 : 0
        var result = AttributedString()
        var i = 0
        while i < chars.count {
            let isMarked = marked[i]
            var j = i
            while j < chars.count && marked[j] == isMarked && (j >= prefixLength) == (i >= prefixLength) { j += 1 }
            var piece = AttributedString(String(chars[i..<j]))
            if i < prefixLength {
                piece.foregroundColor = Color.white.opacity(0.35)
            } else if isMarked {
                piece.foregroundColor = accent
                piece.font = .system(size: size, weight: .bold, design: .monospaced)
            } else {
                piece.foregroundColor = Color.white.opacity(0.82)
            }
            result += piece
            i = j
        }
        return result
    }
}

private struct ActionPill: View {
    let title: String
    let icon: String
    var tint: Color = .white
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(
                    Capsule().fill(prominent ? tint.opacity(hovering ? 0.28 : 0.18)
                                             : Color.white.opacity(hovering ? 0.12 : 0.05))
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(hovering ? 0.18 : 0.08), lineWidth: 1))
                .foregroundStyle(prominent ? tint : (hovering ? Color.primary : Color.secondary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(title)
    }
}

private struct CopyButton: View {
    @Binding var copied: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(copied ? Color.green : Color.white.opacity(0.35))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
