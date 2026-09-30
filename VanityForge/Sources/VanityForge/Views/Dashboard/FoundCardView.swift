import AppKit
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
    /// Свежая находка на секунду-другую "вспыхивает" рамкой/свечением —
    /// приятная обратная связь в духе "поймали", затем гаснет до обычного вида.
    @State private var justArrived = true
    @State private var hovering = false

    private var accent: Color { NetworkVisual.accent(for: event.network) }
    private var balances: [String: Double]? { session.balancesBySeq[event.seq] }

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
                    if let checksum = event.checksumAddress { checksumRow(checksum) }
                    if !event.matchedDesc.isEmpty || !event.foundWords.isEmpty { badgeRow }
                    if event.network == "eth" { balanceRow }
                    privateKeyRow
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .elevatedGlass(accent: accent, cornerRadius: 14, intensity: justArrived ? 1.6 : 1.0)
        .overlay {
            if justArrived {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(accent.opacity(0.9), lineWidth: 1.6)
                ParticleBurst(color: accent, seed: event.seq)
            }
        }
        .shadow(color: accent.opacity(justArrived ? 0.5 : 0), radius: justArrived ? 20 : 0)
        .scaleEffect(justArrived ? 1.015 : (hovering ? 1.008 : 1))
        .rotation3DEffect(.degrees(hovering ? -0.8 : 0), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.5)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
        .onAppear {
            withAnimation(.easeOut(duration: 1.3)) { justArrived = false }
        }
    }

    private var topRow: some View {
        HStack {
            HStack(spacing: 5) {
                NetworkIcon(key: event.network, size: 14)
                Text(event.networkFull)
                    .font(.system(size: 11, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(accent.opacity(0.2)))
            .foregroundStyle(accent)
            Spacer()
            Text(event.foundAt.replacingOccurrences(of: "T", with: "  "))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var addressRow: some View {
        HStack(spacing: 8) {
            Text(event.address)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
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
                .truncationMode(.middle)
            Spacer(minLength: 4)
            CopyButton(copied: $checksumCopied) { copy(checksum) }
        }
    }

    private var badgeRow: some View {
        HStack(spacing: 6) {
            ForEach(event.matchedDesc, id: \.self) { desc in
                Text(desc)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .foregroundStyle(.secondary)
            }
            ForEach(event.foundWords, id: \.self) { word in
                Label(word, systemImage: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow.opacity(0.16)))
                    .foregroundStyle(.yellow)
            }
            Spacer()
            Button {
                revealInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help(session.t(.revealInFinder))
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
            } else {
                Text(session.t(.calculatingBalance))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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
            Text(event.privateKey)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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
    }

    @ViewBuilder
    private var contractRows: some View {
        let address = event.checksumAddress ?? event.address
        HStack(spacing: 8) {
            Text(address)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
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
            Button { revealInFinder() } label: { Image(systemName: "folder").font(.system(size: 11)) }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help(session.t(.revealInFinder))
        }

        if let salt = event.salt {
            HStack(spacing: 8) {
                label(session.t(.create2Salt))
                Text(salt)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                CopyButton(copied: $saltCopied) { copy(salt) }
            }
        }

        HStack(spacing: 14) {
            if let factory = event.factory { smallField(session.t(.create2Factory), factory) }
            if let caller = event.caller { smallField(session.t(.create2Deployer), caller) }
            Spacer(minLength: 0)
        }

        Button {
            copy(clientSummary)
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

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
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

    private func revealInFinder() {
        let url = URL(fileURLWithPath: event.filepath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
        }
        .buttonStyle(.plain)
    }
}
